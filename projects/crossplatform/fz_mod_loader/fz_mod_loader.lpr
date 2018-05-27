library fz_mod_loader;

{$mode delphi}{$H+}

uses
  sysutils,
  windows,
  LogMgr,
  IniFile,
  CommandLineParser,
  FileManager,
  HttpDownloader,
  mutexhunter,
  abstractions,
  Decompressor;

type
  FZDllModFunResult = cardinal;
const
  {%H-}FZ_DLL_MOD_FUN_SUCCESS_LOCK: cardinal = 0;    //Мод успешно загрузился, требуется залочить клиента по name_lock
  FZ_DLL_MOD_FUN_SUCCESS_NOLOCK: cardinal = 1;  //Успех, лочить клиента (с использованием name_lock) пока не надо
  FZ_DLL_MOD_FUN_FAILURE: cardinal = 2;         //Ошибка загрузки мода

type
  FZMasterLinkListAddr = array of string;

  FZFsLtxBuilderSettings = record
    share_patches_dir:boolean;
    full_install:boolean;
    configs_dir:string;
  end;

  FZModSettings = record
    root_dir:string;
    exe_name:string;
    modname:string;
    binlist_url:string;
    gamelist_url:string;
    fsltx_settings:FZFsLtxBuilderSettings;
  end;

var
  _mod_rel_path:PChar;
  _mod_name:PChar;
  _mod_params:PChar;
  _dll_handle:HINST;
  _fz_loader_semaphore_handle:HANDLE;

const
  MAX_NAME_SIZE:cardinal=4096;
  MAX_PARAMS_SIZE:cardinal=4096;
  gamedata_files_list_name:string ='gamedata_filelist.ini';
  engine_files_list_name:string ='engine_filelist.ini';
  master_mods_list_name:string ='master_mods_filelist.ini';
  fsltx_name:string='fsgame.ltx';
  userltx_name:string='user.ltx';
  userdata_dir_name:string='userdata\';
  engine_dir_name:string='bin\';
  patches_dir_name:string='patches\';
  mp_dir_name:string='mp\';

  mod_dir_prefix:PChar='.svn\';
  allowed_symbols_in_mod_name:string='1234567890abcdefghijklmnopqrstuvwxyz_';
  fz_loader_semaphore_name:PAnsiChar='Local\FREEZONE_STK_MOD_LOADER_SEMAPHORE';
  fz_loader_modules_mutex_name:PAnsiChar='Local\FREEZONE_STK_MOD_LOADER_MODULES_MUTEX';

function CreateDownloaderThreadForUrl(url:PAnsiChar):FZDownloaderThread;
begin
  if IsGameSpyDlForced(_mod_params) and (leftstr(url, length('https')) <> 'https') then begin
    FZLogMgr.Get.Write('Creating GS dl thread', FZ_LOG_INFO);
    result:=FZGameSpyDownloaderThread.Create();
  end else begin
    FZLogMgr.Get.Write('Creating CURL dl thread', FZ_LOG_INFO);
    result:=FZCurlDownloaderThread.Create();
  end;
end;

procedure PushToArray(var a:FZMasterLinkListAddr; s:string);
var
  i:integer;
begin
  i:=length(a);
  setlength(a, i+1);
  a[i]:=s;
end;

function DownloadAndParseMasterModsList(var settings:FZModSettings):boolean;
var
  master_links:FZMasterLinkListAddr;
  list_downloaded:boolean;
  dlThread:FZDownloaderThread;
  dl:FZFileDownloader;
  i:integer;
  full_path:string;
  cfg:FZIniFile;
  params_approved:boolean;
  core_params:string;

  tmp_settings:FZModSettings;
const
  DEBUG_MODE_KEY:string='-fz_customlists';
  MASTERLINKS_BINLIST_KEY = 'binlist';
  MASTERLINKS_GAMELIST_KEY = 'gamelist';
  MASTERLINKS_FULLINSTALL_KEY = 'fullinstall';
  MASTERLINKS_SHARED_PATCHES_KEY = 'sharedpatches';
  MASTERLINKS_CONFIGS_DIR_KEY = 'configsdir';
  MASTERLINKS_EXE_NAME_KEY = 'exename';
begin
  result:=false;

  PushToArray(master_links, 'https://raw.githubusercontent.com/FreeZoneMods/modmasterlinks/master/links.ini');
  PushToArray(master_links, 'http://www.gwrmod.tk/files/mods_links.ini');
  PushToArray(master_links, 'http://www.stalker-life.ru/mods_links/links.ini');
  PushToArray(master_links, 'http://stalker.gamepolis.ru/mods_clear_sky/links.ini');
  PushToArray(master_links, 'http://stalker.stagila.ru:8080/stcs_emergency/mods_links.ini');

  list_downloaded:=false;
  full_path:= settings.root_dir+master_mods_list_name;

  dlThread:=CreateDownloaderThreadForUrl(PAnsiChar(master_links[0]));
  for i:=0 to length(master_links)-1 do begin
    dl:=dlThread.CreateDownloader(master_links[i], full_path, 0);
    list_downloaded:=dl.StartSyncDownload();
    dl.Free;
    if list_downloaded then break;
  end;
  dlThread.Free();

  tmp_settings:=settings;
  tmp_settings.binlist_url:=GetCustomBinUrl(_mod_params);
  tmp_settings.gamelist_url:=GetCustomGamedataUrl(_mod_params);
  tmp_settings.exe_name:=GetExeName(_mod_params, '');
  tmp_settings.fsltx_settings.full_install:=IsFullInstallMode(_mod_params);
  tmp_settings.fsltx_settings.share_patches_dir:=IsSharedPatches(_mod_params);
  tmp_settings.fsltx_settings.configs_dir:=GetConfigsDir(_mod_params, '');

  params_approved:=false;
  if list_downloaded then begin
    // Мастер-список успешно скачался, будем парсить его содержимое
    cfg:=FZIniFile.Create(full_path);
    for i:=0 to cfg.GetSectionsCount()-1 do begin
      if cfg.GetSectionName(i) = tmp_settings.modname then begin
        FZLogMgr.Get.Write('Mod '+tmp_settings.modname+' found in master list', FZ_LOG_INFO);
        if (length(tmp_settings.binlist_url) > 0) and (tmp_settings.binlist_url <> cfg.GetStringDef(tmp_settings.modname, MASTERLINKS_BINLIST_KEY, '')) then begin
          FZLogMgr.Get.Write('Master binlist link differs from specified in mod parameters', FZ_LOG_ERROR);
          params_approved:=false;
          break;
        end else if (length(tmp_settings.gamelist_url)>0) and (tmp_settings.gamelist_url <> cfg.GetStringDef(tmp_settings.modname, MASTERLINKS_GAMELIST_KEY, '')) then begin
          FZLogMgr.Get.Write('Master gamelist link differs from specified in mod parameters', FZ_LOG_ERROR);
          params_approved:=false;
          break;
        end;
        tmp_settings.gamelist_url := cfg.GetStringDef(tmp_settings.modname, MASTERLINKS_GAMELIST_KEY, '');
        tmp_settings.binlist_url  := cfg.GetStringDef(tmp_settings.modname, MASTERLINKS_BINLIST_KEY,  '');
        tmp_settings.fsltx_settings.full_install := cfg.GetBoolDef(tmp_settings.modname, MASTERLINKS_FULLINSTALL_KEY, false);
        tmp_settings.fsltx_settings.share_patches_dir:= cfg.GetBoolDef(tmp_settings.modname, MASTERLINKS_SHARED_PATCHES_KEY, false);
        tmp_settings.fsltx_settings.configs_dir:=cfg.GetStringDef(tmp_settings.modname, MASTERLINKS_CONFIGS_DIR_KEY, '');
        tmp_settings.exe_name:=cfg.GetStringDef(tmp_settings.modname, MASTERLINKS_EXE_NAME_KEY, '');
        params_approved := true;
        break;
      end else if (not params_approved) and ( (length(tmp_settings.binlist_url) = 0) or (tmp_settings.binlist_url = cfg.GetStringDef(cfg.GetSectionName(i), MASTERLINKS_BINLIST_KEY, ''))) then begin
        // Ссылка на движок нас удовлетворяет, но надо продолжать проверять остальные секции
        if not params_approved then begin
          if (length(tmp_settings.binlist_url) = 0) then begin
            FZLogMgr.Get.Write('No engine mod, approved', FZ_LOG_INFO);
          end else begin
            FZLogMgr.Get.Write('Engine "'+tmp_settings.binlist_url+'" approved by mod "'+cfg.GetSectionName(i)+'"', FZ_LOG_INFO);
          end;
          params_approved:=true;
        end;
      end;
    end;
    cfg.Free;
  end else begin
    //Список почему-то не скачался. Ограничимся геймдатными модами.
    FZLogMgr.Get.Write('Cannot download master links!', FZ_LOG_ERROR);
    params_approved:=( length(tmp_settings.binlist_url) = 0);
  end;

  core_params:=VersionAbstraction().GetCoreParams();
  if params_approved or (Pos(DEBUG_MODE_KEY, core_params)>0) then begin
    settings:=tmp_settings;
    settings.exe_name:=StringReplace(settings.exe_name, '\', '_', [rfReplaceAll]);
    settings.exe_name:=StringReplace(settings.exe_name, '/', '_', [rfReplaceAll]);
    settings.exe_name:=StringReplace(settings.exe_name, '..', '__', [rfReplaceAll]);
    result:=true;
  end;

end;

function DownloadAndApplyFileList(url:string; list_filename:string; root_dir:string; fileList:FZFiles; update_progress:boolean):boolean;
var
  dl:FZFileDownloader;
  filepath:string;
  cfg:FZIniFile;
  i, files_count:integer;

  section:string;
  fileCheckParams:FZCheckParams;
  fileurl:string;
  filename:string;
  compression:cardinal;
  thread:FZDownloaderThread;
  starttime, last_update_time:cardinal;
const
  MAX_NO_UPDATE_DELTA = 5000;
begin
  result:=false;
  if length(url)=0 then begin
    FZLogMgr.Get.Write('No list URL specified', FZ_LOG_ERROR);
    exit;
  end;

  filepath:=root_dir+list_filename;
  FZLogMgr.Get.Write('Downloading list '+url+' to '+filepath, FZ_LOG_INFO);

  thread:=CreateDownloaderThreadForUrl(PAnsiChar(url));
  dl:=thread.CreateDownloader(url, filepath, 0);
  result:=dl.StartSyncDownload();
  dl.Free();
  thread.Free();
  if not result then begin
    FZLogMgr.Get.Write('Downloading list failed', FZ_LOG_ERROR);
    exit;
  end;
  result:=false;

  cfg:=FZIniFile.Create(filepath);
  files_count:=cfg.GetIntDef('main', 'files_count', 0);
  if files_count = 0 then begin
    FZLogMgr.Get.Write('No files in file list', FZ_LOG_ERROR);
    exit;
  end;

  starttime:=GetCurrentTime();
  last_update_time:=starttime;
  for i:=0 to files_count-1 do begin
    section:='file_'+inttostr(i);
    FZLogMgr.Get.Write('Parsing section '+section, FZ_LOG_INFO);
    filename:=cfg.GetStringDef(section, 'path', '' );
    if (length(filename)=0) then begin
      FZLogMgr.Get.Write('Invalid name for file #'+inttostr(i), FZ_LOG_ERROR);
      exit;
    end;

    if cfg.GetBoolDef(section,'ignore', false) then begin
      if not fileList.AddIgnoredFile(filename) then begin
        FZLogMgr.Get.Write('Cannot add to ignored file #'+inttostr(i)+' ('+filename+')', FZ_LOG_ERROR);
        exit;
      end;
    end else begin
      fileurl:=cfg.GetStringDef(section, 'url', '' );
      if (length(fileurl)=0) then begin
        FZLogMgr.Get.Write('Invalid url for file #'+inttostr(i), FZ_LOG_ERROR);
        exit;
      end;

      compression:=cfg.GetIntDef(section, 'compression', 0);

      fileCheckParams.crc32:=0;
      if not cfg.GetHex(section, 'crc32', fileCheckParams.crc32) then begin
        FZLogMgr.Get.Write('Invalid crc32 for file #'+inttostr(i), FZ_LOG_ERROR);
        exit;
      end;

      fileCheckParams.size:=cfg.GetIntDef(section, 'size', 0);
      if fileCheckParams.size=0 then begin
        FZLogMgr.Get.Write('Invalid size for file #'+inttostr(i), FZ_LOG_ERROR);
        exit;
      end;
      fileCheckParams.md5:=LowerCase(cfg.GetStringDef(section, 'md5', ''));

      if not fileList.UpdateFileInfo(filename, fileurl, compression, fileCheckParams) then begin
        FZLogMgr.Get.Write('Cannot update file info #'+inttostr(i)+' ('+filename+')', FZ_LOG_ERROR);
        exit;
      end;
    end;

    if VersionAbstraction().CheckForUserCancelDownload() then begin
      FZLogMgr.Get.Write('Stop applying file list - user-cancelled', FZ_LOG_ERROR);
      exit;
    end else if update_progress then begin
      if GetCurrentTime() - last_update_time > MAX_NO_UPDATE_DELTA then begin
        VersionAbstraction().SetVisualProgress(100 * i / files_count);
        last_update_time:=GetCurrentTime();
      end;
    end;
  end;
  FZLogMgr.Get.Write('File list "'+list_filename+'" processed, time '+inttostr(GetCurrentTime()-starttime)+' ms', FZ_LOG_INFO);

  cfg.Free;
  result:=true;
end;

function DownloadCallback(info:FZFileActualizingProgressInfo; userdata:pointer):boolean;
var
  progress:single;
  ready:int64;
  last_downloaded_bytes:pint64;
begin
  progress:=0;
  if info.total_mod_size>0 then begin
    ready:=info.total_downloaded+info.total_up_to_date_size;
    if (ready>0) or (ready<=info.total_mod_size) then begin
      progress:=(ready/info.total_mod_size)*100;
    end;
  end;

  last_downloaded_bytes:=userdata;
  if (last_downloaded_bytes^<>info.total_downloaded) then begin
    if (info.status <> FZ_ACTUALIZING_VERIFYING_START) and (info.status <> FZ_ACTUALIZING_VERIFYING) then begin
      FZLogMgr.Get.Write('Downloaded '+inttostr(info.total_downloaded)+', state '+inttostr(cardinal(info.status)), FZ_LOG_DBG);
    end else begin
      if info.status = FZ_ACTUALIZING_VERIFYING_START then begin
        VersionAbstraction().AssignStatus('Verifying downloaded content...');
      end;
      FZLogMgr.Get.Write('Verified '+inttostr(info.total_downloaded)+', state '+inttostr(cardinal(info.status)), FZ_LOG_DBG);
    end;
    last_downloaded_bytes^:=info.total_downloaded;
  end;

  VersionAbstraction().SetVisualProgress(progress);
  result:=not VersionAbstraction().CheckForUserCancelDownload();
end;

function BuildFsGame(filename:string; settings:FZFsLtxBuilderSettings):boolean;
var
  f:textfile;
  opened:boolean;
  tmp:string;
begin
  result:=false;
  opened:=false;
  try
    assignfile(f, filename);
    rewrite(f);
    opened:=true;

    writeln(f,'$mnt_point$=false|false|$fs_root$|gamedata\');

    writeln(f,'$app_data_root$=false |false |$fs_root$|'+userdata_dir_name);
    writeln(f,'$parent_app_data_root$=false |false|'+VersionAbstraction().UpdatePath('$app_data_root$', ''));

    writeln(f,'$parent_game_root$=false|false|'+VersionAbstraction().UpdatePath('$fs_root$', ''));

    if (settings.full_install) then begin
      writeln(f,'$arch_dir$=false| false| $fs_root$');
      writeln(f,'$game_arch_mp$=false| false| $fs_root$| mp\');
      writeln(f,'$arch_dir_levels$=false| false| $fs_root$| levels\');
      writeln(f,'$arch_dir_resources$=false| false| $fs_root$| resources\');
      writeln(f,'$arch_dir_localization$=false| false| $fs_root$| localization\');
    end else begin
      if VersionAbstraction().PathExists('$arch_dir') then begin
        writeln(f,'$arch_dir$=false| false|'+VersionAbstraction().UpdatePath('$arch_dir$', ''));
      end;

      if VersionAbstraction().PathExists('$game_arch_mp$') then begin
        //SACE3 обладает нехорошей привычкой писать сюда db-файлы, одна ошибка - и неработоспособный клиент
        //У нас "безопасное" место для записи - это юзердата (даже в случае ошибки - брикнем мод, не игру)
        //Маппим $game_arch_mp$ в юзердату, а чтобы игра подхватывала оригинальные файлы с картами -
        //создадим еще одну запись
        writeln(f,'$game_arch_mp$=false| false|$app_data_root$');
        writeln(f,'$game_arch_mp_parent$=false| false|'+VersionAbstraction().UpdatePath('$game_arch_mp$', ''));
      end;

      if VersionAbstraction().PathExists('$arch_dir_levels$') then begin
        writeln(f,'$arch_dir_levels$=false| false|'+VersionAbstraction().UpdatePath('$arch_dir_levels$', ''));
      end;

      if VersionAbstraction().PathExists('$arch_dir_resources$') then begin
        writeln(f,'$arch_dir_resources$=false| false|'+VersionAbstraction().UpdatePath('$arch_dir_resources$', ''));
      end;

      if VersionAbstraction().PathExists('$arch_dir_localization$') then begin
       writeln(f,'$arch_dir_localization$=false| false|'+VersionAbstraction().UpdatePath('$arch_dir_localization$', ''));
      end;
    end;

    if VersionAbstraction().PathExists('$arch_dir_patches$') and settings.share_patches_dir then begin
      writeln(f,'$arch_dir_patches$=false| false|'+VersionAbstraction().UpdatePath('$arch_dir_patches$', ''));
      writeln(f,'$arch_dir_second_patches$=false|false|$fs_root$|patches\');
    end else begin
      writeln(f,'$arch_dir_patches$=false|false|$fs_root$|patches\');
    end;

    writeln(f,'$game_data$=false|true|$fs_root$|gamedata\');
    writeln(f,'$game_ai$=true|false|$game_data$|ai\');
    writeln(f,'$game_spawn$=true|false|$game_data$|spawns\');
    writeln(f,'$game_levels$=true|false|$game_data$|levels\');
    writeln(f,'$game_meshes$=true|true|$game_data$|meshes\|*.ogf;*.omf|Game Object files');
    writeln(f,'$game_anims$=true|true|$game_data$|anims\|*.anm;*.anms|Animation files');
    writeln(f,'$game_dm$=true|true|$game_data$|meshes\|*.dm|Detail Model files');
    writeln(f,'$game_shaders$=true|true|$game_data$|shaders\');
    writeln(f,'$game_sounds$=true|true|$game_data$|sounds\');
    writeln(f,'$game_textures$=true|true|$game_data$|textures\');

    if length(settings.configs_dir)>0 then begin
      writeln(f,'$game_config$=true|false|$game_data$|'+settings.configs_dir+'\');
    end else begin
      tmp:=VersionAbstraction().UpdatePath('$game_config$', '');
      if rightstr(tmp, length('config\')) = 'config\' then begin
        writeln(f,'$game_config$=true|false|$game_data$|config\');
      end else begin
        writeln(f,'$game_config$=true|false|$game_data$|configs\');
      end;
    end;
    writeln(f,'$game_weathers$=true|false|$game_config$|environment\weathers');
    writeln(f,'$game_weather_effects$=true|false|$game_config$|environment\weather_effects');
    writeln(f,'$textures$=true|true|$game_data$|textures\');
    writeln(f,'$level$=false|false|$game_levels$');
    writeln(f,'$game_scripts$=true|false|$game_data$|scripts\|*.script|Game script files');
    writeln(f,'$logs$=true|false|$app_data_root$|logs\');
    writeln(f,'$screenshots$=true|false|$app_data_root$|screenshots\');
    writeln(f,'$game_saves$=true|false|$app_data_root$|savedgames\');
    writeln(f,'$mod_dir$=false|false|$fs_root$|mods\');
    writeln(f,'$downloads$=false|false|$app_data_root$');
    result:=true;
  finally
    if (opened) then begin
      CloseFile(f);
    end;
  end;
end;

function CopyFileIfValid(src_path:string; dst_path:string; targetParams:FZCheckParams):boolean;
var
  fileCheckParams:FZCheckParams;
  dst_dir:string;
begin
  result:=false;
  if GetFileChecks(src_path, @fileCheckParams, length(targetParams.md5)>0) then begin
    if CompareFiles(fileCheckParams, targetParams) then begin
      dst_dir:=dst_path;
      while (dst_dir[length(dst_dir)]<>'\') and (dst_dir[length(dst_dir)]<>'/') do begin
        dst_dir:=leftstr(dst_dir,length(dst_dir)-1);
      end;
      ForceDirectories(dst_dir);

      if CopyFile(PAnsiChar(src_path), PAnsiChar(dst_path), false) then begin
        FZLogMgr.Get.Write('Copied '+src_path+' to '+dst_path, FZ_LOG_INFO);
        result:=true;
      end else begin
        FZLogMgr.Get.Write('Cannot copy file '+src_path+' to '+dst_path, FZ_LOG_ERROR);
      end;
    end else begin
      FZLogMgr.Get.Write('Checksum or size not equal to target', FZ_LOG_INFO);
    end;
  end;
end;

procedure PreprocessFiles(files:FZFiles; mod_root:string);
const
  NO_PRELOAD:string='-fz_nopreload';
var
  i:integer;
  e:FZFileItemData;
  core_root:string;
  filename:string;
  src, dst:string;
  disable_preload:boolean;
begin
  disable_preload:=(Pos(NO_PRELOAD, VersionAbstraction().GetCoreParams()) > 0);

  files.AddIgnoredFile(gamedata_files_list_name);
  files.AddIgnoredFile(engine_files_list_name);
  for i:=files.EntriesCount()-1 downto 0 do begin
    e:=files.GetEntry(i);
    if (leftstr(e.name, length(userdata_dir_name))=userdata_dir_name) and (e.required_action=FZ_FILE_ACTION_UNDEFINED) then begin
      //спасаем файлы юзердаты от удаления
      files.UpdateEntryAction(i, FZ_FILE_ACTION_IGNORE);
    end else if (leftstr(e.name, length(engine_dir_name))=engine_dir_name) and (e.required_action=FZ_FILE_ACTION_DOWNLOAD) then begin
      if not disable_preload then begin
        //Проверим, есть ли уже такой файл в текущем движке
        core_root:=VersionAbstraction().GetCoreApplicationPath();
        filename:=e.name;
        delete(filename,1,length(engine_dir_name));
        src:=core_root+filename;
        dst:=mod_root+e.name;
        if CopyFileIfValid(src, dst, e.target) then begin
          files.UpdateEntryAction(i, FZ_FILE_ACTION_NO);
        end;
      end;
    end else if (leftstr(e.name, length(patches_dir_name))=patches_dir_name) and (e.required_action=FZ_FILE_ACTION_DOWNLOAD) then begin
      if not disable_preload and VersionAbstraction().PathExists('$arch_dir_patches$') then begin
        //Проверим, есть ли уже такой файл в текущей копии игры
        filename:=e.name;
        delete(filename,1,length(patches_dir_name));
        src:=VersionAbstraction().UpdatePath('$arch_dir_patches$', filename);
        dst:=mod_root+e.name;
        if CopyFileIfValid(src, dst, e.target) then begin
          files.UpdateEntryAction(i, FZ_FILE_ACTION_NO);
        end;
      end;
    end else if (leftstr(e.name, length(mp_dir_name))=mp_dir_name) and (e.required_action=FZ_FILE_ACTION_DOWNLOAD) then begin
      if not disable_preload and VersionAbstraction().PathExists('$game_arch_mp$') then begin
        //Проверим, есть ли уже такой файл в текущей копии игры
        filename:=e.name;
        delete(filename,1,length(mp_dir_name));
        src:=VersionAbstraction().UpdatePath('$game_arch_mp$', filename);
        dst:=mod_root+e.name;
        if CopyFileIfValid(src, dst, e.target) then begin
          files.UpdateEntryAction(i, FZ_FILE_ACTION_NO);
        end;
      end;
    end;
  end;
end;

function DoWork(modname:string; modpath:string):boolean; //Выполняется в отдельном потоке
var
  ip:string;
  port:integer;
  files:FZFiles;
  last_downloaded_bytes:int64;

  cmdline, cmdapp, workingdir:string;
  si:TStartupInfo;
  pi:TProcessInformation;
  srcname, dstname:string;

  fullPathToCurEngine:PAnsiChar;
  sz:cardinal;

  mod_settings:FZModSettings;
begin
  result:=false;
  //Пока идет коннект(существует уровень) - не начинаем работу
  while VersionAbstraction().CheckForLevelExist() do begin
    Sleep(10);
  end;

  //Пауза для нормального обновления мастер-листа
  Sleep(500);

  FZLogMgr.Get.Write('Starting visual download', FZ_LOG_INFO);
  if not VersionAbstraction().StartVisualDownload() then begin
    FZLogMgr.Get.Write('Cannot start visual download', FZ_LOG_ERROR);
    exit;
  end;

  //Получим путь к корневой (установочной) диектории мода
  mod_settings.modname:=modname;
  mod_settings.root_dir:=VersionAbstraction().UpdatePath('$app_data_root$', modpath);
  if (mod_settings.root_dir[length(mod_settings.root_dir)]<>'\') and (mod_settings.root_dir[length(mod_settings.root_dir)]<>'/') then begin
    mod_settings.root_dir:=mod_settings.root_dir+'\';
  end;
  FZLogMgr.Get.Write('Path to mod is ' + mod_settings.root_dir, FZ_LOG_INFO);

  if not ForceDirectories(mod_settings.root_dir) then begin
    FZLogMgr.Get.Write('Cannot create root directory', FZ_LOG_ERROR);
    exit;
  end;

  VersionAbstraction().AssignStatus('Parsing master links list...');

  if not DownloadAndParseMasterModsList(mod_settings) then begin
    FZLogMgr.Get.Write('Parsing master links list failed!', FZ_LOG_ERROR);
    exit;
  end;

  VersionAbstraction().AssignStatus('Scanning directory...');

  //Просканируем корневую директорию на содержимое
  files := FZFiles.Create();
  if IsGameSpyDlForced(_mod_params) then begin
    files.SetDlMode(FZ_DL_MODE_GAMESPY);
  end else begin
    files.SetDlMode(FZ_DL_MODE_CURL);
  end;
  last_downloaded_bytes:=0;
  files.SetCallback(@DownloadCallback, @last_downloaded_bytes);
  if not files.ScanPath(mod_settings.root_dir) then begin
    FZLogMgr.Get.Write('Scanning root directory failed!', FZ_LOG_ERROR);
    files.Free;
    exit;
  end;

  //Загрузим с сервера требуемую конфигурацию корневой директории и сопоставим ее с текущей
  FZLogMgr.Get.Write('=======Processing game resources list=======', FZ_LOG_INFO);
  if length(mod_settings.gamelist_url)=0 then begin
    FZLogMgr.Get.Write('Empty game files list URL found!', FZ_LOG_ERROR);
    files.Free;
    exit;
  end;

  VersionAbstraction().AssignStatus('Verifying resources...');
  VersionAbstraction().SetVisualProgress(0);
  if not DownloadAndApplyFileList(mod_settings.gamelist_url, gamedata_files_list_name, mod_settings.root_dir, files, true) then begin
    FZLogMgr.Get.Write('Applying game files list failed!', FZ_LOG_ERROR);
    files.Free;
    exit;
  end;

  VersionAbstraction().AssignStatus('Verifying engine...');
  if length(mod_settings.binlist_url)>0 then begin
    if not DownloadAndApplyFileList(mod_settings.binlist_url, engine_files_list_name, mod_settings.root_dir, files, false) then begin
      FZLogMgr.Get.Write('Applying engine files list failed!', FZ_LOG_ERROR);
      files.Free;
      exit;
    end;
  end;

  //удалим файлы из юзердаты из списка синхронизируемых; скопируем доступные файлы вместо загрузки их
  FZLogMgr.Get.Write('=======Preprocessing files=======', FZ_LOG_INFO);

  VersionAbstraction().AssignStatus('Preprocessing files...');

  PreprocessFiles(files, mod_settings.root_dir);
  files.Dump(FZ_LOG_INFO);

  VersionAbstraction().AssignStatus('Downloading content...');

  //Выполним синхронизацию файлов
  FZLogMgr.Get.Write('=======Actualizing game data=======', FZ_LOG_INFO);
  if not files.ActualizeFiles() then begin
    FZLogMgr.Get.Write('Actualizing files failed!', FZ_LOG_ERROR);
    files.Free;
    exit;
  end;

  //Готово
  files.Free;

  VersionAbstraction().AssignStatus('Building fsltx...');

  FZLogMgr.Get.Write('Building fsltx', FZ_LOG_INFO);
  VersionAbstraction().SetVisualProgress(100);

  //Обновим fsgame
  FZLogMgr.Get.Write('full_install '+booltostr(mod_settings.fsltx_settings.full_install, true)+', shared patches '+booltostr(mod_settings.fsltx_settings.share_patches_dir, true), FZ_LOG_INFO);
  if not BuildFsGame(mod_settings.root_dir+fsltx_name, mod_settings.fsltx_settings) then begin
    FZLogMgr.Get.Write('Building fsltx failed!', FZ_LOG_ERROR);
    exit;
  end;

  VersionAbstraction().AssignStatus('Building userltx...');

  //если user.ltx отсутствует в userdata - нужно сделать его там
  if not FileExists(mod_settings.root_dir+userdata_dir_name+userltx_name) then begin
    FZLogMgr.Get.Write('Building userltx', FZ_LOG_INFO);
    //в случае с SACE команда на сохранение не срабатывает, поэтому сначала скопируем файл
    dstname:=mod_settings.root_dir+userdata_dir_name;
    ForceDirectories(dstname);
    dstname:=dstname+userltx_name;
    srcname:=VersionAbstraction().UpdatePath('$app_data_root$', 'user.ltx');
    FZLogMgr.Get.Write('Copy from '+srcname+' to '+dstname, FZ_LOG_INFO);
    CopyFile(PAnsiChar(srcname), PAnsiChar(dstname), false);
    VersionAbstraction().ExecuteConsoleCommand(PAnsiChar('cfg_save '+dstname));
  end;

  VersionAbstraction().AssignStatus('Running game...');

  //Надо стартовать игру с модом
  ip:=GetServerIp(_mod_params);
  if length(ip)=0 then begin
    FZLogMgr.Get.Write('Cannot determine IP address of the server', FZ_LOG_ERROR);
    exit;
  end;

  //Подготовимся к перезапуску
  FZLogMgr.Get.Write('Prepare to restart client '+cmdapp+' '+cmdline, FZ_LOG_INFO);
  port:=GetServerPort(_mod_params);
  if (port<0) or (port>65535) then begin
    FZLogMgr.Get.Write('Cannot determine port', FZ_LOG_ERROR);
    exit;
  end;

  if length(mod_settings.binlist_url) > 0 then begin
    // Нестандартный двиг мода
    cmdapp:=mod_settings.root_dir+'bin\';
    if length(mod_settings.exe_name)>0 then begin
      cmdapp:=cmdapp+mod_settings.exe_name;
      cmdline:=mod_settings.exe_name;
    end else begin
      cmdapp:=cmdapp+VersionAbstraction().GetEngineExeFileName();
      cmdline:=VersionAbstraction().GetEngineExeFileName();
    end;

    //-fzmod - показывает имя мода; -fz_nomod - тключает загрузку модов (чтобы не впасть в рекурсию/старая версия)
    //так как проверка на имя мода идет первой, то все должно работать
    cmdline:= cmdline + ' -fz_nomod -fzmod '+mod_settings.modname+' -start client('+ip+'/port='+inttostr(port)+')';
    workingdir:=mod_settings.root_dir;
  end else begin
    // Используем текущий двиг
    sz :=128;
    fullPathToCurEngine:=nil;
    repeat
      if fullPathToCurEngine <> nil then FreeMem(fullPathToCurEngine, sz);
      sz:=sz*2;
      GetMem(fullPathToCurEngine, sz);
      if fullPathToCurEngine = nil then exit;
    until GetModuleFileName(VersionAbstraction().GetEngineExeModuleAddress(), fullPathToCurEngine, sz) < sz-1;
    cmdapp:=fullPathToCurEngine;
    workingdir:=mod_settings.root_dir;
    cmdline:= VersionAbstraction().GetEngineExeFileName()+' -fz_nomod -fzmod '+mod_settings.modname+' -wosace -start client('+ip+'/port='+inttostr(port)+')';
    FreeMem(fullPathToCurEngine, sz);
  end;

  //Точка невозврата. Убедимся, что пользователь не отменил загрузку
  if VersionAbstraction().CheckForUserCancelDownload() then begin
    FZLogMgr.Get().Write('Cancelled by user', FZ_LOG_ERROR);
    exit;
  end;

  FillMemory(@si, sizeof(si),0);
  FillMemory(@pi, sizeof(pi),0);
  si.cb:=sizeof(si);

  //Прибьем блокирующий запуск нескольких копий сталкера мьютекс
  KillMutex();

  //Запустим клиента
  if (not CreateProcess(PAnsiChar(cmdapp), PAnsiChar(cmdline), nil, nil, false, CREATE_SUSPENDED, nil, PAnsiChar(workingdir),si, pi)) then begin
    FZLogMgr.Get.Write('cmdapp: '+cmdapp, FZ_LOG_ERROR);
    FZLogMgr.Get.Write('cmdline: '+cmdline, FZ_LOG_ERROR);
    FZLogMgr.Get.Write('Cannot run application', FZ_LOG_ERROR);
  end else begin
    ResumeThread(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    result:=true;
  end;
end;

procedure DecompressorLogger(text:PAnsiChar); stdcall;
const
  DECOMPRESS_LBL:string='[DECOMPR]';
begin
  FZLogMgr.Get.Write(DECOMPRESS_LBL+text, FZ_LOG_INFO);
end;

function InitModules():boolean;
begin
  result:=true;
  // Init low-level
  result:=result and abstractions.Init();
  result:=result and Decompressor.Init(@DecompressorLogger);
  // Init high-level
  result:=result and LogMgr.Init();

  FZLogMgr.Get.SetSeverity(FZ_LOG_INFO);
  FZLogMgr.Get.Write('Modules inited', FZ_LOG_INFO);
end;

procedure FreeStringMemory();
begin
  if _mod_name <> nil then VirtualFree(_mod_name, 0, MEM_RELEASE);
  if _mod_rel_path <> nil then VirtualFree(_mod_rel_path, 0, MEM_RELEASE);
  if _mod_params <> nil then VirtualFree(_mod_params, 0, MEM_RELEASE);
end;

function AllocateStringMemory():boolean;
begin
  //Выделим память под аргументы
  _mod_name:=VirtualAlloc(nil, MAX_NAME_SIZE, MEM_COMMIT, PAGE_READWRITE);
  _mod_rel_path:=VirtualAlloc(nil, MAX_NAME_SIZE, MEM_COMMIT, PAGE_READWRITE);
  _mod_params:=VirtualAlloc(nil, MAX_PARAMS_SIZE, MEM_COMMIT, PAGE_READWRITE);

  result:=(_mod_rel_path <> nil) and (_mod_params<>nil) and (_mod_rel_path<>nil);
  if not result then begin
    FreeStringMemory();
  end;
end;

procedure FreeModules();
begin
  FZLogMgr.Get.Write('Free modules', FZ_LOG_INFO);
  Decompressor.Free();
  LogMgr.Free();
  abstractions.Free();
end;

function ThreadBody_internal():boolean; stdcall;
var
  mutex:HANDLE;
  i:cardinal;
begin
  result:=false;

  //Убедимся, что нам разрешено выделить ресурсы
  mutex:=CreateMutex(nil, FALSE, fz_loader_modules_mutex_name);
  if (mutex = 0) or (mutex = INVALID_HANDLE_VALUE) then begin
    exit;
  end;

  if WaitForSingleObject(mutex, INFINITE) <> WAIT_OBJECT_0 then begin
    CloseHandle(mutex);
    exit;
  end;

  if not InitModules() then begin
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    exit;
  end;

  FZLogMgr.Get.SetSeverity(FZ_LOG_IMPORTANT_INFO);
  FZLogMgr.Get.Write( 'FreeZone Mod Loader', FZ_LOG_IMPORTANT_INFO );
  FZLogMgr.Get.Write( 'Build date: ' + {$INCLUDE %DATE}, FZ_LOG_IMPORTANT_INFO );
  FZLogMgr.Get.Write( 'Mod name is "'+_mod_name+'"', FZ_LOG_IMPORTANT_INFO );
  FZLogMgr.Get.Write( 'Mod params "'+_mod_params+'"', FZ_LOG_IMPORTANT_INFO );
  FZLogMgr.Get.SetSeverity(GetLogSeverity(_mod_params));
  FZLogMgr.Get.Write('Working thread started', FZ_LOG_INFO);

  result:=DoWork(_mod_name, _mod_rel_path);

  if not result then begin
    FZLogMgr.Get.Write('Loading failed!', FZ_LOG_ERROR);
    VersionAbstraction().SetVisualProgress(0);
    VersionAbstraction().AssignStatus('Downloading failed. Try again.');

    i:=0;
    while (i<10000) and (not VersionAbstraction.CheckForUserCancelDownload()) and (not VersionAbstraction.CheckForLevelExist()) do begin
      Sleep(1);
      i:=i+1;
    end;
    VersionAbstraction().StopVisualDownload();
  end;

  FZLogMgr.Get.Write('Releasing resources', FZ_LOG_INFO);
  VersionAbstraction().ExecuteConsoleCommand(PAnsiChar('flush'));

  FreeStringMemory();
  FreeModules();

  ReleaseMutex(mutex);
  CloseHandle(mutex);
end;

//Похоже, компиль не просекает, что FreeLibraryAndExitThread не возвращает управление. Из-за этого локальные переменные оказываются
//не зачищены, и это рушит нам приложение. Для решения вопроса делаем свой асмовый враппер, лишенный указанных недостатков.
function ThreadBody():dword; stdcall;
asm
  call ThreadBody_internal

  push [_dll_handle]
  push eax

  //Хэндл ДЛЛ надо занулить до освобождения семафора, но саму ДЛЛ выгрузить уже в самом конце - поэтому он сохранен в стеке
  mov _dll_handle, dword 0

  push [_fz_loader_semaphore_handle] // для вызова CloseHandle
  push dword 0
  push dword 1
  push [_fz_loader_semaphore_handle]
  mov [_fz_loader_semaphore_handle], 0
  call ReleaseSemaphore
  call CloseHandle

  pop eax //Результат работы
  pop ebx //сохраненный хэндл
  cmp al, 0
  je @error_happen
  push dword 0
  call dword GetCurrentProcess
  push eax
  call TerminateProcess

  @error_happen:
  push dword 0
  push ebx
  call FreeLibraryAndExitThread
end;

function RunModLoad():boolean;
var
  path:string;
begin
  result:=false;

  //Захватим ДЛЛ для предотвращения выгрузки во время работы потока загрузчика
  path:=SysUtils.GetModuleName(HInstance);
  FZLogMgr.Get.Write('Path to loader is: '+path, FZ_LOG_INFO);
  _dll_handle:=LoadLibrary(PAnsiChar(path));
  if _dll_handle = 0 then begin
    FZLogMgr.Get().Write('Cannot acquire DLL '+path, FZ_LOG_ERROR);
    exit;
  end;

  //Начинаем синхронизацию файлов мода в отдельном потоке
  FZLogMgr.Get().Write('Starting working thread', FZ_LOG_INFO);

  if not VersionAbstraction().ThreadSpawn(uintptr(@ThreadBody), 0) then begin
    FZLogMgr.Get().Write('Cannot start thread', FZ_LOG_ERROR);
    FreeLibrary(_dll_handle);
    _dll_handle:=0;
    exit;
  end;

  result:=true;
end;

procedure AbortConnection();
begin
  FZLogMgr.Get().Write('Aborting connection', FZ_LOG_DBG);
  VersionAbstraction.AbortConnection();
end;

function ValidateInput(mod_name:PAnsiChar; mod_params:PAnsiChar):boolean;
var
  i:cardinal;
begin
  result:=false;

  if Int64(length(mod_name))+Int64(length(mod_dir_prefix))>=Int64(MAX_NAME_SIZE-1) then begin
    FZLogMgr.Get.Write('Too long mod name, exiting', FZ_LOG_ERROR);
    exit;
  end;

  if length(mod_params)>=MAX_PARAMS_SIZE-1 then begin
    FZLogMgr.Get.Write('Too long mod params, exiting', FZ_LOG_ERROR);
    exit;
  end;

  i:=0;
  while(mod_name[i]<>chr(0)) do begin
    if pos(mod_name[i], allowed_symbols_in_mod_name) = 0 then begin
      FZLogMgr.Get.Write('Invalid mod name, exiting', FZ_LOG_ERROR);
      exit;
    end;
    i:=i+1;
  end;

  result:=true;
end;

function ModLoad_internal(mod_name:PAnsiChar; mod_params:PAnsiChar):FZDllModFunResult; stdcall;
var
  mutex:HANDLE;
begin
  result:=FZ_DLL_MOD_FUN_FAILURE;
  mutex:=CreateMutex(nil, FALSE, fz_loader_modules_mutex_name);
  if (mutex = 0) or (mutex = INVALID_HANDLE_VALUE) then begin
    exit;
  end;

  if WaitForSingleObject(mutex, 0) = WAIT_OBJECT_0 then begin
    //Отлично, основной поток закачки не стартует, пока мы не отпустим мьютекс
    if InitModules() then begin
      AbortConnection();

      if ValidateInput(mod_name, mod_params) then begin
        if AllocateStringMemory() then begin
          StrCopy(_mod_name, mod_name);
          StrCopy(_mod_params, mod_params);

          FZLogMgr.Get.SetSeverity(GetLogSeverity(mod_params));

          //Благодаря этому хаку с префиксом, игра не полезет подгружать файлы мода при запуске оригинального клиента
          StrCopy(_mod_rel_path, mod_dir_prefix);
          StrCopy(@_mod_rel_path[length(mod_dir_prefix)], mod_name);

          if RunModLoad() then begin
            // Не лочимся - загрузка может окончиться неудачно либо быть отменена
            // кроме того, повторный коннект при активной загрузке и выставленной инфе о моде приведет к неожиданным результатам
            result:=FZ_DLL_MOD_FUN_SUCCESS_NOLOCK
          end else begin
            FreeStringMemory();
          end;
        end else begin
          FZLogMgr.Get.Write('Cannot allocate string memory!', FZ_LOG_ERROR);
        end;
      end;

      //Основной поток закачки сам проинициализирует их заново - если не освобождать, происходит какая-то фигня при освобождении из другого потока.
      FreeModules();
    end;
    ReleaseMutex(mutex);
    CloseHandle(mutex);
  end;
end;

//Схема работы загрузчика с ипользованием с мастер-списка модов:
// 1) Скачиваем мастер-список модов
// 2) Если мастер-список скачан и мод с таким названием есть в списке - используем ссылки на движок и геймдату
//    из этого списка; если заданы кастомные и не совпадающие с теми, которые в списке - ругаемся и не работаем
// 3) Если мастер-список скачан, но мода с таким названием в нем нет - убеждаемся, что ссылка на движок либо не
//    задана (используется текущий), либо есть среди других модов, либо на клиенте активен дебаг-режим. Если не
//    выполняется ничего из этого - ругаемся и не работаем, если выполнено - используем указанные ссылки
// 4) Если мастер-список НЕ скачан - убеждаемся, что ссылка на движок либо не задана (надо использовать текущий),
//    либо активен дебаг-режим на клиенте. Если это не выполнено - ругаемся и не работаем, иначе используем
//    предоставленные пользователем ссылки.
// 5) Скачиваем сначала геймдатный список, затем движковый (чтобы не дать возможность переопределить в первом файлы второго)
// 6) Актуализируем файлы и рестартим клиент

//Доступные ключи запуска, передающиеся в mod_params:
//-binlist <URL> - ссылка на адрес, по которому берется список файлов движка (для работы требуется запуск клиента с ключлм -fz_custom_bin)
//-gamelist <URL> - ссылка на адрес, по которому берется список файлов мода (геймдатных\патчей)
//-srv <IP> - IP-адрес сервера, к которому необходимо присоединиться после запуска мода
//-srvname <domainname> - доменное имя, по которому располагается сервер. Можно использовать вместо параметра -srv в случае динамического IP сервера
//-port <number> - порт сервера
//-gamespymode - стараться использовать загрузку средствами GameSpy
//-fullinstall - мод представляет собой самостоятельную копию игры, связь с файлами оригинальной не требуется
//-sharedpatches - использовать общую с инсталляцией игры директорию патчей
//-logsev <number> - уровень серьезности логируемых сообщений, по умолчанию FZ_LOG_ERROR
//-configsdir <string> - директория конфигов
//-exename <string> - имя исполняемого файла мода

function ModLoad(mod_name:PAnsiChar; mod_params:PAnsiChar):FZDllModFunResult; stdcall;
var
  semaphore:HANDLE;
begin
  result:=FZ_DLL_MOD_FUN_FAILURE;
  semaphore := CreateSemaphore(nil, 1, 1, fz_loader_semaphore_name);
  if (semaphore = INVALID_HANDLE_VALUE) or ( semaphore = 0 ) then begin
    exit;
  end;

  if (WaitForSingleObject(semaphore, 0) = WAIT_OBJECT_0) then begin
    //Отлично, семафор наш. Сохраним хендл на него для последующего освобождения
    _fz_loader_semaphore_handle:=semaphore;

    _dll_handle:=0;
    result:=ModLoad_internal(mod_name, mod_params);

    //В случае успеха семафор будет разлочен в другом треде после окончания загрузки.
    if result = FZ_DLL_MOD_FUN_FAILURE then begin
      if _dll_handle <> 0 then begin
        FreeLibrary(_dll_handle);
        _dll_handle:=0;
      end;

      _fz_loader_semaphore_handle:=INVALID_HANDLE_VALUE;
      ReleaseSemaphore(semaphore, 1, nil);
      CloseHandle(semaphore);
    end;
  end else begin
    //Не повезло, сворачиваемся.
    CloseHandle(semaphore);
  end;

end;

{$IFNDEF RELEASE}
procedure ModLoadTest(); stdcall;
begin
  ModLoad('soc20006h', ' -srvname localhost -srvport 5449 '{ ' -srvname localhost -srvport 5449 '});
end;
{$ENDIF}

exports
{$IFNDEF RELEASE}
  ModLoadTest,
{$ENDIF}
  ModLoad;

{$R *.res}

begin
  _dll_handle:=0;
end.

