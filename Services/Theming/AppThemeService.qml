pragma Singleton

import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI

Singleton {
  id: root

  readonly property string colorsApplyScript: Quickshell.shellDir + '/Bin/colors-apply.sh'
  property string pendingPreviewWallpaper: ""
  property string pendingPreviewMode: ""

  Connections {
    target: WallpaperService

    // When the wallpaper changes, regenerate with Matugen if necessary
    function onWallpaperChanged(screenName, path) {
      if (screenName === Screen.name && Settings.data.colorSchemes.useWallpaperColors) {
        generateFromWallpaper();
      }
    }
    function onWallpaperPreviewReady(originalPath, previewPath) {
      if (pendingPreviewWallpaper !== "" && pendingPreviewWallpaper === originalPath) {
        const mode = pendingPreviewMode || (Settings.data.colorSchemes.darkMode ? "dark" : "light");
        pendingPreviewWallpaper = "";
        pendingPreviewMode = "";
        TemplateProcessor.processWallpaperColors(previewPath, mode);
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
    const wallpaperPath = WallpaperService.getWallpaper(Screen.name);
    if (!wallpaperPath) {
      Logger.e("AppThemeService", "No wallpaper found");
      return;
    }
    const mode = Settings.data.colorSchemes.darkMode ? "dark" : "light";
    const entry = WallpaperService.getWallpaperEntry(wallpaperPath);
    const targetPath = entry.type === "video" ? entry.previewPath : entry.path;

    if (entry.type === "video" && (!targetPath || targetPath === entry.path)) {
      pendingPreviewWallpaper = entry.path;
      pendingPreviewMode = mode;
      WallpaperService.generateWallpaperPreview(entry.path);
      return;
    }

    TemplateProcessor.processWallpaperColors(targetPath, mode);
  }

  function generateFromPredefinedScheme(schemeData) {
    Logger.i("AppThemeService", "Generating templates from predefined color scheme");
    const mode = Settings.data.colorSchemes.darkMode ? "dark" : "light";
    TemplateProcessor.processPredefinedScheme(schemeData, mode);
  }
}
