pragma Singleton

import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI

Singleton {
  id: root

  readonly property string colorsApplyScript: Quickshell.shellDir + '/Bin/colors-apply.sh'
  property var previewReadyHandler: null
  property var matugenPreviewProcess: null

  Connections {
    target: WallpaperService

    // When the wallpaper changes, regenerate with Matugen if necessary
    function onWallpaperChanged(screenName, path) {
      if (screenName === Screen.name && Settings.data.colorSchemes.useWallpaperColors) {
        generateFromWallpaper();
      }
    }
  }

  Connections {
    target: Settings.data.colorSchemes
    function onDarkModeChanged() {
      Logger.d("AppThemeService", "Detected dark mode change");
      generate();
    }
  }

  // PUBLIC FUNCTIONS
  function init() {
    Logger.i("AppThemeService", "Service started");
  }

  function generate() {
    if (Settings.data.colorSchemes.useWallpaperColors) {
      generateFromWallpaper();
    } else {
      // applyScheme will trigger template generation via schemeReader.onLoaded
      ColorSchemeService.applyScheme(Settings.data.colorSchemes.predefinedScheme);
    }
  }

  function generateFromWallpaper() {
    const wp = WallpaperService.getWallpaper(Screen.name);
    if (!wp) {
      Logger.e("AppThemeService", "No wallpaper found");
      return;
    }
    const mode = Settings.data.colorSchemes.darkMode ? "dark" : "light";
    const isVideo = WallpaperService.getWallpaperType(wp) === "video";
    const preview = WallpaperService.getPreviewPath(wp, true);

    // If we already have a preview (image or generated video frame), use it immediately.
    if (preview) {
      TemplateProcessor.processWallpaperColors(preview, mode);
      return;
    }

    // For videos, force-generate a first-frame preview and feed that to Matugen.
    if (isVideo) {
      generateMatugenPreviewForVideo(wp, mode);
      return;
    }

    // Fallback for images when no preview is needed/available
    TemplateProcessor.processWallpaperColors(wp, mode);
  }

  function generateMatugenPreviewForVideo(path, mode) {
    // Tear down any in-flight handler/process to avoid duplicate callbacks
    if (previewReadyHandler) {
      try {
        WallpaperService.wallpaperPreviewReady.disconnect(previewReadyHandler);
      } catch (e) {
      }
      previewReadyHandler = null;
    }
    if (matugenPreviewProcess) {
      try {
        matugenPreviewProcess.running = false;
        matugenPreviewProcess.destroy();
      } catch (e) {
      }
      matugenPreviewProcess = null;
    }

    const previewPath = WallpaperService.buildPreviewPath ? WallpaperService.buildPreviewPath(path) : "";
    const cacheDirEsc = Settings.cacheDirImagesWallpapers.replace(/'/g, "'\\''");
    const pathEsc = path.replace(/'/g, "'\\''");
    const previewEsc = previewPath.replace(/'/g, "'\\''");

    const processString = `
    import QtQuick
    import Quickshell.Io
    Process {
      id: process
      command: ["bash", "-lc", "mkdir -p '${cacheDirEsc}' && command -v ffmpeg >/dev/null 2>&1 && ffmpeg -y -v error -i '${pathEsc}' -frames:v 1 -vf \\"thumbnail,scale=min(1920\\\\,iw):-1\\" '${previewEsc}'"]
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
    `;

    const processObject = Qt.createQmlObject(processString, root, "MatugenPreview_" + Math.random().toString(36).substr(2, 6));
    matugenPreviewProcess = processObject;

    const handleExit = function (exitCode) {
      matugenPreviewProcess = null;
      processObject.destroy();

      if (exitCode === 0 && previewPath) {
        // Populate cache and notify listeners so selectors pick up the preview too
        WallpaperService.previewCache[path] = previewPath;
        WallpaperService.wallpaperPreviewReady(path, previewPath);
        TemplateProcessor.processWallpaperColors(previewPath, mode);
      } else {
        Logger.w("AppThemeService", "Failed to generate video preview for Matugen, exit:", exitCode);
        const fallback = WallpaperService.getPreviewPath(path, false) || path;
        TemplateProcessor.processWallpaperColors(fallback, mode);
      }
    };

    processObject.exited.connect(handleExit);
    processObject.running = true;
  }

  function generateFromPredefinedScheme(schemeData) {
    Logger.i("AppThemeService", "Generating templates from predefined color scheme");
    const mode = Settings.data.colorSchemes.darkMode ? "dark" : "light";
    TemplateProcessor.processPredefinedScheme(schemeData, mode);
  }
}
