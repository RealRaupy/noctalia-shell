pragma Singleton
import Qt.labs.folderlistmodel

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../../Helpers/sha256.js" as Sha256

Singleton {
  id: root

  readonly property ListModel fillModeModel: ListModel {}
  readonly property string defaultDirectory: Settings.preprocessPath(Settings.data.wallpaper.directory)
  readonly property var imageExtensions: ["jpg", "jpeg", "png", "pnm", "bmp", "webp"]
  readonly property var videoExtensions: ["mp4", "webm", "mov", "mkv", "gif"]
  readonly property string steamWorkshopDirectory: Settings.preprocessPath("~/.local/share/Steam/steamapps/workshop/content/431960/")
  property var previewCache: ({})
  property var previewProcesses: ({})
  property var previewQueue: []
  property var previewScanProcesses: ({})

  // All available wallpaper transitions
  readonly property ListModel transitionsModel: ListModel {}

  // All transition keys but filter out "none" and "random" so we are left with the real transitions
  readonly property var allTransitions: Array.from({
                                                     "length": transitionsModel.count
                                                   }, (_, i) => transitionsModel.get(i).key).filter(key => key !== "random" && key != "none")

  property var wallpaperLists: ({})
  property int scanningCount: 0

  // Cache for current wallpapers - can be updated directly since we use signals for notifications
  property var currentWallpapers: ({})

  property bool isInitialized: false
  property string wallpaperCacheFile: ""

  readonly property bool scanning: (scanningCount > 0)
  readonly property string noctaliaDefaultWallpaper: Quickshell.shellDir + "/Assets/Wallpaper/noctalia.png"
  property string defaultWallpaper: noctaliaDefaultWallpaper

  // Signals for reactive UI updates
  signal wallpaperChanged(string screenName, string path)
  // Emitted when a wallpaper changes
  signal wallpaperDirectoryChanged(string screenName, string directory)
  // Emitted when a monitor's directory changes
  signal wallpaperListChanged(string screenName, int count)
  // Emitted when a wallpaper preview becomes available
  signal wallpaperPreviewReady(string originalPath, string previewPath)
  signal audioFocusChanged(string path)

  property string activeAudioPath: ""

  // Emitted when available wallpapers list changes
  Connections {
    target: Settings.data.wallpaper
    function onDirectoryChanged() {
      root.refreshWallpapersList();
      // Emit directory change signals for monitors using the default directory
      if (!Settings.data.wallpaper.enableMultiMonitorDirectories) {
        // All monitors use the main directory
        for (var i = 0; i < Quickshell.screens.length; i++) {
          root.wallpaperDirectoryChanged(Quickshell.screens[i].name, root.defaultDirectory);
        }
      } else {
        // Only monitors without custom directories are affected
        for (var i = 0; i < Quickshell.screens.length; i++) {
          var screenName = Quickshell.screens[i].name;
          var monitor = root.getMonitorConfig(screenName);
          if (!monitor || !monitor.directory) {
            root.wallpaperDirectoryChanged(screenName, root.defaultDirectory);
          }
        }
      }
    }
    function onEnableMultiMonitorDirectoriesChanged() {
      root.refreshWallpapersList();
      // Notify all monitors about potential directory changes
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var screenName = Quickshell.screens[i].name;
        root.wallpaperDirectoryChanged(screenName, root.getMonitorDirectory(screenName));
      }
    }
    function onRandomEnabledChanged() {
      root.toggleRandomWallpaper();
    }
    function onRandomIntervalSecChanged() {
      root.restartRandomWallpaperTimer();
    }
    function onRecursiveSearchChanged() {
      root.refreshWallpapersList();
    }
    function onUseSteamWallpapersChanged() {
      root.refreshWallpapersList();
    }
    function onSteamWallpaperIntegrationChanged() {
      if (!Settings.data.wallpaper.steamWallpaperIntegration) {
        Settings.data.wallpaper.useSteamWallpapers = false;
      }
      root.refreshWallpapersList();
    }
    function onUseWallhavenChanged() {
      if (Settings.data.wallpaper.useWallhaven) {
        Settings.data.wallpaper.useSteamWallpapers = false;
      }
    }
    function onVideoPlaybackEnabledChanged() {
      root.refreshWallpapersList();
    }
    function onVideoAudioMutedChanged() {
      root.audioFocusChanged(root.activeAudioPath);
    }
    function onVideoAudioVolumeChanged() {
      root.audioFocusChanged(root.activeAudioPath);
    }
  }

  // -------------------------------------------------
  function init() {
    Logger.i("Wallpaper", "Service started");

    translateModels();

    // Initialize cache file path
    Qt.callLater(() => {
                   if (typeof Settings !== 'undefined' && Settings.cacheDir) {
                     wallpaperCacheFile = Settings.cacheDir + "wallpapers.json";
                     wallpaperCacheView.path = wallpaperCacheFile;
                   }
                 });

    // Note: isInitialized will be set to true in wallpaperCacheView.onLoaded
    Logger.d("Wallpaper", "Triggering initial wallpaper scan");
    Qt.callLater(refreshWallpapersList);
  }

  // -------------------------------------------------
  function translateModels() {
    // Wait for i18n to be ready by retrying every time
    if (!I18n.isLoaded) {
      Qt.callLater(translateModels);
      return;
    }

    // Populate fillModeModel with translated names
    fillModeModel.append({
                           "key": "center",
                           "name": I18n.tr("wallpaper.fill-modes.center"),
                           "uniform": 0.0
                         });
    fillModeModel.append({
                           "key": "crop",
                           "name": I18n.tr("wallpaper.fill-modes.crop"),
                           "uniform": 1.0
                         });
    fillModeModel.append({
                           "key": "fit",
                           "name": I18n.tr("wallpaper.fill-modes.fit"),
                           "uniform": 2.0
                         });
    fillModeModel.append({
                           "key": "stretch",
                           "name": I18n.tr("wallpaper.fill-modes.stretch"),
                           "uniform": 3.0
                         });

    // Populate transitionsModel with translated names
    transitionsModel.append({
                              "key": "none",
                              "name": I18n.tr("wallpaper.transitions.none")
                            });
    transitionsModel.append({
                              "key": "random",
                              "name": I18n.tr("wallpaper.transitions.random")
                            });
    transitionsModel.append({
                              "key": "fade",
                              "name": I18n.tr("wallpaper.transitions.fade")
                            });
    transitionsModel.append({
                              "key": "disc",
                              "name": I18n.tr("wallpaper.transitions.disc")
                            });
    transitionsModel.append({
                              "key": "stripes",
                              "name": I18n.tr("wallpaper.transitions.stripes")
                            });
    transitionsModel.append({
                              "key": "wipe",
                              "name": I18n.tr("wallpaper.transitions.wipe")
                            });
  }

  // -------------------------------------------------------------------
  function getFillModeUniform() {
    for (var i = 0; i < fillModeModel.count; i++) {
      const mode = fillModeModel.get(i);
      if (mode.key === Settings.data.wallpaper.fillMode) {
        return mode.uniform;
      }
    }
    // Fallback to crop
    return 1.0;
  }

  function isVideoFile(path) {
    if (!path || typeof path !== "string") {
      return false;
    }
    var ext = path.split('.').pop().toLowerCase();
    return videoExtensions.indexOf(ext) !== -1;
  }

  function isImageFile(path) {
    if (!path || typeof path !== "string") {
      return false;
    }
    var ext = path.split('.').pop().toLowerCase();
    return imageExtensions.indexOf(ext) !== -1;
  }

  function getWallpaperType(path) {
    if (isVideoFile(path) && Settings.data.wallpaper.videoPlaybackEnabled) {
      return "video";
    }
    return "image";
  }

  function getPreviewPath(path) {
    if (!path || path === "") {
      return "";
    }
    var hash = Sha256.sha256(path);
    return Settings.cacheDirImagesWallpapers + hash + "@384x384.png";
  }

  function fileExists(path) {
    if (!path) {
      return false;
    }
    try {
      var xhr = new XMLHttpRequest();
      xhr.open("HEAD", "file://" + path, false);
      xhr.send();
      return xhr.status === 200 || xhr.status === 0;
    } catch (e) {
      return false;
    }
  }

  function generateWallpaperPreview(path) {
    if (!path || !isVideoFile(path)) {
      return;
    }
    var previewPath = getPreviewPath(path);

    if (previewCache[path] === undefined) {
      if (fileExists(previewPath)) {
        previewCache[path] = previewPath;
        wallpaperPreviewReady(path, previewPath);
        return;
      }
    }

    if (previewCache[path] && previewCache[path] !== true) {
      wallpaperPreviewReady(path, previewCache[path]);
      return;
    }

    // Skip if already generating or generated
    if (previewProcesses[path]) {
      return;
    }

    previewCache[path] = previewCache[path] || true;

    // Throttle concurrent generations to keep UI responsive (single ffmpeg at a time)
    if (Object.keys(previewProcesses).length >= 1) {
      if (previewQueue.indexOf(path) === -1) {
        previewQueue.push(path);
      }
      return;
    }

    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: previewProcess
      command: ["ffmpeg", "-y", "-i", "${path.replace(/"/g, '\\"')}", "-vf", "thumbnail,scale='min(384,iw)':-2", "-frames:v", "1", "-update", "1", "${previewPath.replace(/"/g, '\\"')}"]
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }`;

    var processObject = Qt.createQmlObject(processString, root, "WallpaperPreview_" + Sha256.sha256(path).substr(0, 8));
    previewProcesses[path] = processObject;

    var handler = function (exitCode) {
      if (exitCode === 0) {
        previewCache[path] = previewPath;
        wallpaperPreviewReady(path, previewPath);
      } else {
        Logger.w("Wallpaper", "Preview generation failed for", path, "exit:", exitCode, "stderr:", processObject.stderr.text);
        previewCache[path] = false;
      }
      delete previewProcesses[path];
      processObject.destroy();
      if (previewQueue.length > 0) {
        var nextPath = previewQueue.shift();
        Qt.callLater(() => generateWallpaperPreview(nextPath));
      }
    };

    processObject.exited.connect(handler);
    processObject.running = true;
  }

  function getPreviewForDisplay(path) {
    if (!path || path === "") {
      return "";
    }
    if (!isVideoFile(path)) {
      return path;
    }
    var previewPath = getPreviewPath(path);
    if (!previewCache[path]) {
      generateWallpaperPreview(path);
      return path;
    }
    if (previewCache[path] === true) {
      return path;
    }
    return previewCache[path] || previewPath;
  }

  function getWallpaperEntry(path) {
    return {
      "path": path,
      "type": getWallpaperType(path),
      "previewPath": getPreviewForDisplay(path)
    };
  }

  function setActiveAudioPath(path) {
    activeAudioPath = path || "";
    audioFocusChanged(activeAudioPath);
  }

  function clearActiveAudioPath(path) {
    if (!path || path === activeAudioPath) {
      activeAudioPath = "";
      audioFocusChanged(activeAudioPath);
    }
  }

  function computeAudioMuted(path) {
    if (!Settings.data.wallpaper.videoPlaybackEnabled || Settings.data.wallpaper.videoAudioMuted) {
      return true;
    }
    if (Settings.data.wallpaper.videoAudioMode === "primary" && path && activeAudioPath && activeAudioPath !== path) {
      return true;
    }
    return false;
  }

  function syncAudioOutput(audioOutput, path) {
    if (!audioOutput) {
      return;
    }
    audioOutput.volume = Settings.data.wallpaper.videoAudioVolume;
    audioOutput.muted = computeAudioMuted(path);
  }

  // -------------------------------------------------------------------
  // Get specific monitor wallpaper data
  function getMonitorConfig(screenName) {
    var monitors = Settings.data.wallpaper.monitorDirectories;
    if (monitors !== undefined) {
      for (var i = 0; i < monitors.length; i++) {
        if (monitors[i].name !== undefined && monitors[i].name === screenName) {
          return monitors[i];
        }
      }
    }
  }

  // -------------------------------------------------------------------
  // Get specific monitor directory
  function getMonitorDirectory(screenName) {
    if (!Settings.data.wallpaper.enableMultiMonitorDirectories) {
      return root.defaultDirectory;
    }

    var monitor = getMonitorConfig(screenName);
    if (monitor !== undefined && monitor.directory !== undefined) {
      return Settings.preprocessPath(monitor.directory);
    }

    // Fall back to the main/single directory
    return root.defaultDirectory;
  }

  // -------------------------------------------------------------------
  // Set specific monitor directory
  function setMonitorDirectory(screenName, directory) {
    var monitors = Settings.data.wallpaper.monitorDirectories || [];
    var found = false;

    // Create a new array with updated values
    var newMonitors = monitors.map(function (monitor) {
      if (monitor.name === screenName) {
        found = true;
        return {
          "name": screenName,
          "directory": directory,
          "wallpaper": monitor.wallpaper || ""
        };
      }
      return monitor;
    });

    if (!found) {
      newMonitors.push({
                         "name": screenName,
                         "directory": directory,
                         "wallpaper": ""
                       });
    }

    // Update Settings with new array to ensure proper persistence
    Settings.data.wallpaper.monitorDirectories = newMonitors.slice();
    root.wallpaperDirectoryChanged(screenName, Settings.preprocessPath(directory));
  }

  // -------------------------------------------------------------------
  // Get specific monitor wallpaper - now from cache
  function getWallpaper(screenName) {
    return currentWallpapers[screenName] || root.defaultWallpaper;
  }

  // -------------------------------------------------------------------
  function changeWallpaper(path, screenName) {
    if (screenName !== undefined) {
      _setWallpaper(screenName, path);
    } else {
      // If no screenName specified change for all screens
      for (var i = 0; i < Quickshell.screens.length; i++) {
        _setWallpaper(Quickshell.screens[i].name, path);
      }
    }
  }

  // -------------------------------------------------------------------
  function _setWallpaper(screenName, path) {
    if (path === "" || path === undefined) {
      return;
    }

    if (screenName === undefined) {
      Logger.w("Wallpaper", "setWallpaper", "no screen specified");
      return;
    }

    //Logger.i("Wallpaper", "setWallpaper on", screenName, ": ", path)

    // Check if wallpaper actually changed
    var oldPath = currentWallpapers[screenName] || "";
    var wallpaperChanged = (oldPath !== path);

    if (!wallpaperChanged) {
      // No change needed
      return;
    }

    // Update cache directly
    currentWallpapers[screenName] = path;

    if (isVideoFile(path)) {
      generateWallpaperPreview(path);
    }

    // Save to cache file with debounce
    saveTimer.restart();

    // Emit signal for this specific wallpaper change
    root.wallpaperChanged(screenName, path);

    // Restart the random wallpaper timer
    if (randomWallpaperTimer.running) {
      randomWallpaperTimer.restart();
    }
  }

  // -------------------------------------------------------------------
  function setRandomWallpaper() {
    Logger.d("Wallpaper", "setRandomWallpaper");

    if (Settings.data.wallpaper.enableMultiMonitorDirectories) {
      // Pick a random wallpaper per screen
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var screenName = Quickshell.screens[i].name;
        var wallpaperList = getWallpapersList(screenName);

        if (wallpaperList.length > 0) {
          var randomIndex = Math.floor(Math.random() * wallpaperList.length);
          var randomPath = wallpaperList[randomIndex];
          changeWallpaper(randomPath, screenName);
        }
      }
    } else {
      // Pick a random wallpaper common to all screens
      // We can use any screenName here, so we just pick the primary one.
      var wallpaperList = getWallpapersList(Screen.name);
      if (wallpaperList.length > 0) {
        var randomIndex = Math.floor(Math.random() * wallpaperList.length);
        var randomPath = wallpaperList[randomIndex];
        changeWallpaper(randomPath, undefined);
      }
    }
  }

  // -------------------------------------------------------------------
  function toggleRandomWallpaper() {
    Logger.d("Wallpaper", "toggleRandomWallpaper");
    if (Settings.data.wallpaper.randomEnabled) {
      restartRandomWallpaperTimer();
      setRandomWallpaper();
    }
  }

  // -------------------------------------------------------------------
  function restartRandomWallpaperTimer() {
    if (Settings.data.wallpaper.isRandom) {
      randomWallpaperTimer.restart();
    }
  }

  // -------------------------------------------------------------------
  function getWallpapersList(screenName) {
    if (screenName != undefined && wallpaperLists[screenName] != undefined) {
      return wallpaperLists[screenName];
    }
    return [];
  }

  // -------------------------------------------------------------------
  function refreshWallpapersList() {
    Logger.d("Wallpaper", "refreshWallpapersList", "recursive:", Settings.data.wallpaper.recursiveSearch);
    scanningCount = 0;

    if (isSteamSourceActive()) {
      scanSteamWorkshop();
      return;
    }

    if (Settings.data.wallpaper.recursiveSearch) {
      // Use Process-based recursive search for all screens
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var screenName = Quickshell.screens[i].name;
        var directory = getMonitorDirectory(screenName);
        scanDirectoryRecursive(screenName, directory);
      }
    } else {
      // Use FolderListModel (non-recursive)
      // Force refresh by toggling each scanner's currentDirectory
      for (var i = 0; i < wallpaperScanners.count; i++) {
        var scanner = wallpaperScanners.objectAt(i);
        if (scanner) {
          // Capture scanner in closure
          (function (s) {
            var directory = root.getMonitorDirectory(s.screenName);
            // Trigger a change by setting to /tmp (always exists) then back to the actual directory
            // Note: This causes harmless Qt warnings (QTBUG-52262) but is necessary to force FolderListModel to re-scan
            s.currentDirectory = "/tmp";
            Qt.callLater(function () {
              s.currentDirectory = directory;
            });
          })(scanner);
        }
      }
    }
  }

  // Process instances for recursive scanning (one per screen)
  property var recursiveProcesses: ({})

  function isSteamSourceActive() {
    return Settings.data.wallpaper.steamWallpaperIntegration && Settings.data.wallpaper.useSteamWallpapers && !Settings.data.wallpaper.useWallhaven;
  }

  function shouldSkipSteamFile(path) {
    if (!path) {
      return false;
    }
    var base = path.split('/').pop().toLowerCase();
    return base.startsWith("preview.");
  }

  // -------------------------------------------------------------------
  function scanDirectoryRecursive(screenName, directory) {
    if (!directory || directory === "") {
      Logger.w("Wallpaper", "Empty directory for", screenName);
      wallpaperLists[screenName] = [];
      wallpaperListChanged(screenName, 0);
      return;
    }

    // Cancel any existing scan for this screen
    if (recursiveProcesses[screenName]) {
      Logger.d("Wallpaper", "Cancelling existing scan for", screenName);
      recursiveProcesses[screenName].running = false;
      recursiveProcesses[screenName].destroy();
      delete recursiveProcesses[screenName];
      scanningCount = Math.max(0, scanningCount - 1);
    }

    scanningCount++;
    Logger.i("Wallpaper", "Starting recursive scan for", screenName, "in", directory);

    // Create Process component inline
    var processComponent = Qt.createComponent("", root);
    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
    id: process
    command: ["find", "-L", "` + directory + `", "-type", "f", "(", "-iname", "*.jpg", "-o", "-iname", "*.jpeg", "-o", "-iname", "*.png", "-o", "-iname", "*.gif", "-o", "-iname", "*.pnm", "-o", "-iname", "*.bmp", "-o", "-iname", "*.webp", "-o", "-iname", "*.mp4", "-o", "-iname", "*.webm", "-o", "-iname", "*.mov", "-o", "-iname", "*.mkv", ")"]
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    }
    `;

    var processObject = Qt.createQmlObject(processString, root, "RecursiveScan_" + screenName);

    // Store reference to avoid garbage collection
    recursiveProcesses[screenName] = processObject;

    var handler = function (exitCode) {
      scanningCount--;
      Logger.d("Wallpaper", "Process exited with code", exitCode, "for", screenName);
      if (exitCode === 0) {
        var lines = processObject.stdout.text.split('\n');
        var files = [];
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (line !== '') {
            files.push(line);
          }
        }
        // Sort files for consistent ordering
        files.sort();
        wallpaperLists[screenName] = files;
        Logger.i("Wallpaper", "Recursive scan completed for", screenName, "found", files.length, "files");
        wallpaperListChanged(screenName, files.length);
      } else {
        Logger.w("Wallpaper", "Recursive scan failed for", screenName, "exit code:", exitCode, "(directory might not exist)");
        wallpaperLists[screenName] = [];
        wallpaperListChanged(screenName, 0);
      }
      // Clean up
      delete recursiveProcesses[screenName];
      processObject.destroy();
    };

    processObject.exited.connect(handler);
    Logger.d("Wallpaper", "Starting process for", screenName);
    processObject.running = true;
  }

  function scanSteamWorkshop() {
    var directory = steamWorkshopDirectory;
    if (!directory || directory === "") {
      Logger.w("Wallpaper", "Steam workshop directory is empty");
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var screenName = Quickshell.screens[i].name;
        wallpaperLists[screenName] = [];
        wallpaperListChanged(screenName, 0);
      }
      return;
    }

    scanningCount++;
    Logger.i("Wallpaper", "Starting Steam workshop scan in", directory);

    var processComponent = Qt.createComponent("", root);
    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: process
      command: ["find", "-L", "${directory}", "-type", "f", "(", "-iname", "*.mp4", "-o", "-iname", "*.webm", "-o", "-iname", "*.mov", "-o", "-iname", "*.mkv", "-o", "-iname", "*.gif", ")"]
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
    `;

    var processObject = Qt.createQmlObject(processString, root, "SteamWorkshopScan");

    var handler = function (exitCode) {
      scanningCount--;
      if (exitCode === 0) {
        var lines = processObject.stdout.text.split('\n');
        var files = [];
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (line !== '' && !shouldSkipSteamFile(line)) {
            files.push(line);
          }
        }
        files.sort();
        for (var s = 0; s < Quickshell.screens.length; s++) {
          var screenName = Quickshell.screens[s].name;
          wallpaperLists[screenName] = files;
          wallpaperListChanged(screenName, files.length);
        }
        Logger.i("Wallpaper", "Steam workshop scan completed, found", files.length, "files");
      } else {
        Logger.w("Wallpaper", "Steam workshop scan failed with exit code", exitCode);
        for (var s = 0; s < Quickshell.screens.length; s++) {
          var screenName = Quickshell.screens[s].name;
          wallpaperLists[screenName] = [];
          wallpaperListChanged(screenName, 0);
        }
      }
      processObject.destroy();
    };

    processObject.exited.connect(handler);
    processObject.running = true;
  }

  function generateAllVideoPreviews() {
    var seen = {};
    var screens = Object.keys(wallpaperLists);
    for (var i = 0; i < screens.length; i++) {
      var list = wallpaperLists[screens[i]] || [];
      for (var j = 0; j < list.length; j++) {
        var path = list[j];
        if (isVideoFile(path) && !seen[path]) {
          seen[path] = true;
          generateWallpaperPreview(path);
        }
      }
    }

    if (isSteamSourceActive() && screens.length === 0) {
      generateAllVideoPreviewsRecursive();
    }
  }

  function generateAllVideoPreviewsRecursive() {
    if (isSteamSourceActive()) {
      generatePreviewsInDirectory(steamWorkshopDirectory);
      return;
    }

    var directories = [];
    if (Settings.data.wallpaper.enableMultiMonitorDirectories) {
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var monitor = getMonitorConfig(Quickshell.screens[i].name);
        if (monitor && monitor.directory) {
          directories.push(Settings.preprocessPath(monitor.directory));
        }
      }
    }
    if (directories.length === 0 && defaultDirectory) {
      directories.push(defaultDirectory);
    }

    var uniqueDirs = {};
    for (var d = 0; d < directories.length; d++) {
      var dir = directories[d];
      if (dir && !uniqueDirs[dir]) {
        uniqueDirs[dir] = true;
        generatePreviewsInDirectory(dir);
      }
    }
  }

  function generatePreviewsInDirectory(directory) {
    if (!directory || directory === "") {
      return;
    }

    var key = "preview-" + directory;
    if (previewScanProcesses[key]) {
      return;
    }

    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: process
      command: ["find", "-L", "${directory}", "-type", "f", "(", "-iname", "*.mp4", "-o", "-iname", "*.webm", "-o", "-iname", "*.mov", "-o", "-iname", "*.mkv", "-o", "-iname", "*.gif", ")"]
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }`;

    var processObject = Qt.createQmlObject(processString, root, "PreviewPrewarm_" + Sha256.sha256(directory).substr(0, 8));
    previewScanProcesses[key] = processObject;

    var handler = function (exitCode) {
      if (exitCode === 0) {
        var lines = processObject.stdout.text.split('\n');
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (line !== "") {
            if (directory === steamWorkshopDirectory && shouldSkipSteamFile(line)) {
              continue;
            }
            generateWallpaperPreview(line);
          }
        }
      } else {
        Logger.w("Wallpaper", "Preview scan failed for", directory, "exit:", exitCode);
      }
      delete previewScanProcesses[key];
      processObject.destroy();
    };

    processObject.exited.connect(handler);
    processObject.running = true;
  }

  // -------------------------------------------------------------------
  // -------------------------------------------------------------------
  // -------------------------------------------------------------------
  Timer {
    id: randomWallpaperTimer
    interval: Settings.data.wallpaper.randomIntervalSec * 1000
    running: Settings.data.wallpaper.randomEnabled
    repeat: true
    onTriggered: setRandomWallpaper()
    triggeredOnStart: false
  }

  // Instantiator (not Repeater) to create FolderListModel for each monitor
  Instantiator {
    id: wallpaperScanners
    active: !Settings.data.wallpaper.recursiveSearch && !root.isSteamSourceActive()
    model: Quickshell.screens
    delegate: FolderListModel {
      property string screenName: modelData.name
      property string currentDirectory: root.getMonitorDirectory(screenName)

      folder: "file://" + currentDirectory
      nameFilters: root.imageExtensions.concat(root.videoExtensions).map(ext => "*." + ext)
      showDirs: false
      sortField: FolderListModel.Name

      // Watch for directory changes via property binding
      onCurrentDirectoryChanged: {
        folder = "file://" + currentDirectory;
      }

      Component.onCompleted: {
        // Connect to directory change signal
        root.wallpaperDirectoryChanged.connect(function (screen, directory) {
          if (screen === screenName) {
            currentDirectory = directory;
          }
        });
      }

      onStatusChanged: {
        if (status === FolderListModel.Null) {
          // Flush the list
          root.wallpaperLists[screenName] = [];
          root.wallpaperListChanged(screenName, 0);
        } else if (status === FolderListModel.Loading) {
          // Flush the list
          root.wallpaperLists[screenName] = [];
          scanningCount++;
        } else if (status === FolderListModel.Ready) {
          var files = [];
          for (var i = 0; i < count; i++) {
            var directory = root.getMonitorDirectory(screenName);
            var filepath = directory + "/" + get(i, "fileName");
            files.push(filepath);
          }

          // Update the list
          root.wallpaperLists[screenName] = files;

          scanningCount--;
          Logger.d("Wallpaper", "List refreshed for", screenName, "count:", files.length);
          root.wallpaperListChanged(screenName, files.length);
        }
      }
    }
  }

  // -------------------------------------------------------------------
  // Cache file persistence
  // -------------------------------------------------------------------
  FileView {
    id: wallpaperCacheView
    printErrors: false
    watchChanges: false

    adapter: JsonAdapter {
      id: wallpaperCacheAdapter
      property var wallpapers: ({})
      property string defaultWallpaper: root.noctaliaDefaultWallpaper
    }

    onLoaded: {
      // Load wallpapers from cache file
      root.currentWallpapers = wallpaperCacheAdapter.wallpapers || {};

      // Load default wallpaper from cache if it exists, otherwise use Noctalia default
      if (wallpaperCacheAdapter.defaultWallpaper && wallpaperCacheAdapter.defaultWallpaper !== "") {
        root.defaultWallpaper = wallpaperCacheAdapter.defaultWallpaper;
        Logger.d("Wallpaper", "Loaded default wallpaper from cache:", wallpaperCacheAdapter.defaultWallpaper);
      } else {
        root.defaultWallpaper = root.noctaliaDefaultWallpaper;
        Logger.d("Wallpaper", "Using Noctalia default wallpaper");
      }

      Logger.d("Wallpaper", "Loaded wallpapers from cache file:", Object.keys(root.currentWallpapers).length, "screens");
      root.isInitialized = true;
    }

    onLoadFailed: error => {
      // File doesn't exist yet or failed to load - initialize with empty state
      root.currentWallpapers = {};
      Logger.d("Wallpaper", "Cache file doesn't exist or failed to load, starting with empty wallpapers");
      root.isInitialized = true;
    }
  }

  Timer {
    id: saveTimer
    interval: 500
    repeat: false
    onTriggered: {
      wallpaperCacheAdapter.wallpapers = root.currentWallpapers;
      wallpaperCacheAdapter.defaultWallpaper = root.defaultWallpaper;
      wallpaperCacheView.writeAdapter();
      Logger.d("Wallpaper", "Saved wallpapers to cache file");
    }
  }
}
