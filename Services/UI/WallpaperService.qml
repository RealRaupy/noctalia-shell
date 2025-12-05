pragma Singleton
import Qt.labs.folderlistmodel

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import "../../Helpers/sha256.js" as Checksum

Singleton {
  id: root

  readonly property ListModel fillModeModel: ListModel {}
  readonly property string defaultDirectory: Settings.preprocessPath(Settings.data.wallpaper.directory)
  readonly property string steamWorkshopDirectory: Settings.preprocessPath(Quickshell.env("HOME") + "/.local/share/Steam/steamapps/workshop/content/431960/")

  // All available wallpaper transitions
  readonly property ListModel transitionsModel: ListModel {}

  // All transition keys but filter out "none" and "random" so we are left with the real transitions
  readonly property var allTransitions: Array.from({
                                                     "length": transitionsModel.count
                                                   }, (_, i) => transitionsModel.get(i).key).filter(key => key !== "random" && key != "none")

  property var wallpaperLists: ({})
  property int scanningCount: 0
  readonly property bool scanning: (scanningCount > 0)

  // Cache for current wallpapers - can be updated directly since we use signals for notifications
  property var currentWallpapers: ({})

  // Treat GIFs as video so we always grab a first-frame preview and avoid heavy animation in selectors
  readonly property var imageExtensions: ["jpg", "jpeg", "png", "pnm", "bmp", "webp"]
  readonly property var videoExtensions: ["mp4", "webm", "mov", "mkv", "gif"]
  readonly property int videoPreviewSize: 384

  // Cache for previews (video -> generated thumbnail path)
  property var previewCache: ({})
  property var previewProcesses: ({})
  property var bulkPreviewProcess: null
  property bool bulkPreviewRunning: false
  property var bulkScanProcess: null
  property var steamScanProcess: null

  property bool isInitialized: false
  property string activeAudioPath: ""

  // Shared audio output for wallpaper videos
  property AudioOutput wallpaperAudioOutput: AudioOutput {
    id: wallpaperAudioOutputImpl
    muted: root.computeAudioMuted()
    volume: Settings.data.wallpaper.videoAudioVolume
    objectName: "Noctalia Wallpaper"
  }

  // Signals for reactive UI updates
  signal wallpaperChanged(string screenName, string path)
  // Emitted when a wallpaper changes
  signal wallpaperDirectoryChanged(string screenName, string directory)
  // Emitted when a monitor's directory changes
  signal wallpaperListChanged(string screenName, int count)
  // Emitted when a wallpaper preview becomes available (primarily for video thumbnails)
  signal wallpaperPreviewReady(string originalPath, string previewPath)
  // Emitted when the wallpaper audio focus changes (path of active video or "")
  signal audioFocusChanged(string activePath)

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
    function onUseWallhavenChanged() {
      if (Settings.data.wallpaper.useWallhaven && Settings.data.wallpaper.useSteamWallpapers) {
        Settings.data.wallpaper.useSteamWallpapers = false;
      }
    }
    function onUseSteamWallpapersChanged() {
      root.refreshWallpapersList();
    }
    function onSteamWallpaperIntegrationChanged() {
      if (!Settings.data.wallpaper.steamWallpaperIntegration && Settings.data.wallpaper.useSteamWallpapers) {
        Settings.data.wallpaper.useSteamWallpapers = false;
        return;
      }
      root.refreshWallpapersList();
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
    function onVideoPlaybackEnabledChanged() {
      root.syncAudioOutput();
    }
    function onVideoAudioMutedChanged() {
      root.syncAudioOutput();
    }
    function onVideoAudioVolumeChanged() {
      root.syncAudioOutput();
    }
  }

  // -------------------------------------------------
  function init() {
    Logger.i("Wallpaper", "Service started");

    translateModels();

    // Load wallpapers from ShellState first (faster), then fall back to Settings
    currentWallpapers = ({});

    if (typeof ShellState !== 'undefined' && ShellState.isLoaded) {
      var cachedWallpapers = ShellState.getWallpapers();
      if (cachedWallpapers && Object.keys(cachedWallpapers).length > 0) {
        currentWallpapers = cachedWallpapers;
        Logger.d("Wallpaper", "Loaded wallpapers from ShellState");
      } else {
        // Fall back to Settings if ShellState is empty
        loadFromSettings();
      }
    } else {
      // ShellState not ready yet, load from Settings
      loadFromSettings();
    }

    syncAudioOutput();

    isInitialized = true;
    Logger.d("Wallpaper", "Triggering initial wallpaper scan");
    Qt.callLater(refreshWallpapersList);
  }

  function loadFromSettings() {
    var monitors = Settings.data.wallpaper.monitors || [];
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].name && monitors[i].wallpaper) {
        currentWallpapers[monitors[i].name] = monitors[i].wallpaper;
      }
    }
    Logger.d("Wallpaper", "Loaded wallpapers from Settings");

    // Migration is now handled in Settings.qml
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

  function isSteamSourceActive() {
    return Settings.data.wallpaper.useSteamWallpapers
           && !Settings.data.wallpaper.useWallhaven
           && Settings.data.wallpaper.steamWallpaperIntegration;
  }

  function shouldSkipSteamFile(path) {
    if (!path) {
      return true;
    }
    var name = path.split("/").pop().toLowerCase();
    return name.startsWith("preview.");
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

  // -------------------------------------------------------------------
  // Get specific monitor wallpaper data
  function getMonitorConfig(screenName) {
    var monitors = Settings.data.wallpaper.monitors;
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
    var monitors = Settings.data.wallpaper.monitors || [];
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
    Settings.data.wallpaper.monitors = newMonitors.slice();
    root.wallpaperDirectoryChanged(screenName, Settings.preprocessPath(directory));
  }

  // -------------------------------------------------------------------
  function isVideo(path) {
    if (!path || typeof path !== "string")
      return false;
    var lower = path.toLowerCase();
    for (var i = 0; i < videoExtensions.length; i++) {
      if (lower.endsWith("." + videoExtensions[i])) {
        return true;
      }
    }
    return false;
  }

  function getWallpaperType(path) {
    // When video playback is disabled, treat all wallpapers as images to avoid spawning video players.
    if (Settings.data?.wallpaper && Settings.data.wallpaper.videoPlaybackEnabled === false) {
      return "image";
    }
    return isVideo(path) ? "video" : "image";
  }

  function buildPreviewPath(path) {
    if (!path) {
      return "";
    }
    var hash = Checksum.sha256(path);
    return `${Settings.cacheDirImagesWallpapers}${hash}@${videoPreviewSize}x${videoPreviewSize}.png`;
  }

  // Return the preview path if available. For videos, starts generation on demand.
  function getPreviewPath(path, generateIfMissing) {
    if (!path) {
      return "";
    }
    if (!isVideo(path)) {
      return path;
    }

    var previewPath = buildPreviewPath(path);
    if (previewCache[path]) {
      return previewCache[path];
    }

    if (generateIfMissing === undefined || generateIfMissing) {
      ensureVideoPreview(path, previewPath);
    }

    // Preview not ready yet
    return "";
  }

  // Convenience for UI: return preview if ready, otherwise a safe placeholder (no video paths).
  function getPreviewForDisplay(path) {
    if (!path) {
      return "";
    }
    if (!isVideo(path)) {
      return path;
    }
    return getPreviewPath(path, true);
  }

  // Unified wallpaper data used by views and mutagen
  function getWallpaperEntry(path) {
    return {
      "path": path,
      "type": getWallpaperType(path),
      "previewPath": getPreviewForDisplay(path)
    };
  }

  function computeAudioMuted() {
    return !Settings.data.wallpaper.videoPlaybackEnabled
           || Settings.data.wallpaper.videoAudioMuted;
  }

  function getPrimaryAudioMonitor() {
    if (Quickshell.screens && Quickshell.screens.length > 0) {
      return Quickshell.screens[0].name || "";
    }
    return "";
  }

  function syncAudioOutput() {
    wallpaperAudioOutput.volume = Settings.data.wallpaper.videoAudioVolume;
    wallpaperAudioOutput.muted = computeAudioMuted();
  }

  function setActiveAudioPath(path) {
    if (activeAudioPath === path) {
      return;
    }
    activeAudioPath = path || "";
    audioFocusChanged(activeAudioPath);
  }

  function clearActiveAudioPath(path) {
    if (!path || activeAudioPath !== path) {
      return;
    }
    activeAudioPath = "";
    audioFocusChanged(activeAudioPath);
  }

  function ensureVideoPreview(path, previewPath) {
    if (!path) {
      return;
    }
    if (previewProcesses[path]) {
      return;
    }

    var previewTarget = previewPath || buildPreviewPath(path);
    var pathEsc = path.replace(/'/g, "'\\''");
    var previewEsc = previewTarget.replace(/'/g, "'\\''");
    var cacheDirEsc = Settings.cacheDirImagesWallpapers.replace(/'/g, "'\\''");

    // Single-process pipeline: check existing file, ensure ffmpeg is present, then grab first frame
    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: process
      command: ["bash", "-lc", "mkdir -p '${cacheDirEsc}' && { test -s '${previewEsc}' && exit 0; } && command -v ffmpeg >/dev/null 2>&1 && ffmpeg -y -v error -i '${pathEsc}' -frames:v 1 -vf \\"thumbnail,scale=min(${videoPreviewSize}\\\\,iw):-2\\" '${previewEsc}'"]
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
    `;

    var processObject = Qt.createQmlObject(processString, root, "PreviewGenerator_" + Checksum.sha256(path).substr(0, 8));
    previewProcesses[path] = processObject;

    var handler = function (exitCode) {
      delete previewProcesses[path];
      processObject.destroy();

      if (exitCode === 0) {
        previewCache[path] = previewTarget;
        wallpaperPreviewReady(path, previewTarget);
      } else {
        Logger.w("Wallpaper", "Failed to generate preview for", path, "exit:", exitCode);
      }
    };

    processObject.exited.connect(handler);
    processObject.running = true;
  }

  // Generate previews for all known video wallpapers across screens (best-effort)
  function generateAllVideoPreviews() {
    if (bulkPreviewRunning) {
      Logger.i("Wallpaper", "Bulk video preview generation already running");
      return;
    }

    var screens = Quickshell.screens || [];
    var videoPaths = [];
    var previewPaths = [];

    for (var i = 0; i < screens.length; i++) {
      var list = getWallpapersList(screens[i].name) || [];
      for (var j = 0; j < list.length; j++) {
        var path = list[j];
        if (isVideo(path)) {
          videoPaths.push(path);
          previewPaths.push(buildPreviewPath(path));
        }
      }
    }

    if (videoPaths.length === 0) {
      Logger.i("Wallpaper", "No video wallpapers found for bulk preview generation");
      return;
    }

    var cacheDirEsc = Settings.cacheDirImagesWallpapers.replace(/'/g, "'\\''");
    var scriptLines = ["mkdir -p '" + cacheDirEsc + "'"];

    for (var k = 0; k < videoPaths.length; k++) {
      var pEsc = videoPaths[k].replace(/'/g, "'\\''");
      var prevEsc = previewPaths[k].replace(/'/g, "'\\''");
      scriptLines.push(`{ test -s '${prevEsc}' || ffmpeg -y -v error -i '${pEsc}' -frames:v 1 -vf "thumbnail,scale=min(${videoPreviewSize}\\,iw):-2" '${prevEsc}'; } || true`);
    }

    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: process
      command: ["bash", "-lc", "${scriptLines.join(" && ")}"]
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
    `;

    if (bulkPreviewProcess) {
      try {
        bulkPreviewProcess.running = false;
        bulkPreviewProcess.destroy();
      } catch (e) {
      }
      bulkPreviewProcess = null;
    }

    bulkPreviewProcess = Qt.createQmlObject(processString, root, "BulkPreviewProcess");
    bulkPreviewRunning = true;

    var handler = function (exitCode) {
      bulkPreviewRunning = false;
      bulkPreviewProcess = null;

      // Populate cache and notify listeners so selectors refresh
      for (var t = 0; t < videoPaths.length; t++) {
        previewCache[videoPaths[t]] = previewPaths[t];
        wallpaperPreviewReady(videoPaths[t], previewPaths[t]);
      }

      Logger.i("Wallpaper", "Bulk video preview generation finished with code", exitCode, "for", videoPaths.length, "videos");
      try {
        this.destroy();
      } catch (e) {
      }
    };

    bulkPreviewProcess.exited.connect(handler);
    bulkPreviewProcess.running = true;
  }

  // Recursively scan configured directories for videos and trigger preview generation
  function generateAllVideoPreviewsRecursive() {
    if (bulkScanProcess) {
      Logger.i("Wallpaper", "Bulk video preview scan already running");
      return;
    }

    var dirs = [];
    if (isSteamSourceActive()) {
      if (steamWorkshopDirectory && dirs.indexOf(steamWorkshopDirectory) === -1) {
        dirs.push(steamWorkshopDirectory);
      }
    } else if (Settings.data.wallpaper.enableMultiMonitorDirectories) {
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var d = getMonitorDirectory(Quickshell.screens[i].name);
        if (d && dirs.indexOf(d) === -1) {
          dirs.push(d);
        }
      }
    } else {
      if (defaultDirectory && dirs.indexOf(defaultDirectory) === -1) {
        dirs.push(defaultDirectory);
      }
    }

    if (dirs.length === 0) {
      Logger.i("Wallpaper", "No directories configured for preview scan");
      return;
    }

    var patterns = isSteamSourceActive()
                   ? ["*.mp4", "*.webm", "*.mov", "*.mkv"]
                   : ["*.mp4", "*.webm", "*.mov", "*.mkv", "*.gif"];
    var findParts = [];
    dirs.forEach(function (dir) {
      var esc = dir.replace(/'/g, "'\\''");
      findParts.push("find -L '" + esc + "' -type f \\( " + patterns.map(function (p) {
        return "-iname '" + p + "'";
      }).join(" -o ") + " \\)");
    });
    var command = findParts.join(" ; ");

    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: process
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
    `;

    bulkScanProcess = Qt.createQmlObject(processString, root, "BulkVideoScan");
    bulkScanProcess.command = ["bash", "-lc", command];

    var handleExit = function () {
      var output = bulkScanProcess.stdout.text || "";
      bulkScanProcess.destroy();
      bulkScanProcess = null;

      var lines = output.split("\\n");
      lines.forEach(function (line) {
        var p = line.trim();
        if (p !== "" && isVideo(p)) {
          ensureVideoPreview(p, buildPreviewPath(p));
        }
      });
    };

    bulkScanProcess.exited.connect(handleExit);
    bulkScanProcess.running = true;
  }

  // -------------------------------------------------------------------
  // Get specific monitor wallpaper - now from cache
  function getWallpaper(screenName) {
    return currentWallpapers[screenName] || Settings.defaultWallpaper;
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

    // Kick off preview generation for videos
    if (isVideo(path)) {
      ensureVideoPreview(path, buildPreviewPath(path));
    }

    // Save to ShellState (wallpaper paths now only stored here, not in Settings)
    if (typeof ShellState !== 'undefined' && ShellState.isLoaded) {
      ShellState.setWallpapers(currentWallpapers);
    }

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
    Logger.d("Wallpaper", "refreshWallpapersList", "recursive:", Settings.data.wallpaper.recursiveSearch, "steam:", isSteamSourceActive());
    scanningCount = 0;

    if (isSteamSourceActive()) {
      for (var key in recursiveProcesses) {
        if (recursiveProcesses.hasOwnProperty(key)) {
          try {
            recursiveProcesses[key].running = false;
            recursiveProcesses[key].destroy();
          } catch (e) {
          }
          delete recursiveProcesses[key];
        }
      }
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

  function scanSteamWorkshop() {
    var directory = steamWorkshopDirectory;
    var screens = Quickshell.screens || [];

    if (!directory || directory === "") {
      Logger.w("Wallpaper", "Empty Steam workshop directory");
      for (var i = 0; i < screens.length; i++) {
        var screenName = screens[i].name;
        wallpaperLists[screenName] = [];
        wallpaperListChanged(screenName, 0);
      }
      return;
    }

    if (steamScanProcess) {
      try {
        steamScanProcess.running = false;
        steamScanProcess.destroy();
      } catch (e) {
      }
      steamScanProcess = null;
      scanningCount = Math.max(0, scanningCount - 1);
    }

    scanningCount++;
    Logger.i("Wallpaper", "Starting Steam workshop scan in", directory);

    var processString = `
    import QtQuick
    import Quickshell.Io
    Process {
    id: process
    command: ["find", "-L", "` + directory + `", "-type", "f", "(", "-iname", "*.mp4", "-o", "-iname", "*.webm", "-o", "-iname", "*.mov", "-o", "-iname", "*.mkv", ")"]
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    }
    `;

    var processObject = Qt.createQmlObject(processString, root, "SteamWorkshopScan");
    steamScanProcess = processObject;

    var handler = function (exitCode) {
      scanningCount--;
      var files = [];

      if (exitCode === 0) {
        var lines = processObject.stdout.text.split('\n');
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (line !== '' && isVideo(line) && !shouldSkipSteamFile(line)) {
            files.push(line);
          }
        }
        files.sort();
        Logger.i("Wallpaper", "Steam workshop scan completed, found", files.length, "videos");
      } else {
        Logger.w("Wallpaper", "Steam workshop scan failed for", directory, "exit code:", exitCode);
      }

      for (var j = 0; j < screens.length; j++) {
        var screenName = screens[j].name;
        var listCopy = files.slice();
        wallpaperLists[screenName] = listCopy;
        wallpaperListChanged(screenName, listCopy.length);
      }

      steamScanProcess = null;
      try {
        processObject.destroy();
      } catch (e) {
      }
    };

    processObject.exited.connect(handler);
    processObject.running = true;
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
      scanningCount--;
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
    model: Quickshell.screens
    delegate: FolderListModel {
      property string screenName: modelData.name
      property string currentDirectory: root.getMonitorDirectory(screenName)

      folder: "file://" + currentDirectory
      nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.gif", "*.pnm", "*.bmp", "*.webp", "*.mp4", "*.webm", "*.mov", "*.mkv"]
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
        if (root.isSteamSourceActive()) {
          return;
        }
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
}
