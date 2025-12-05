import QtQuick

QtObject {
  id: root

  // Migrate from version < 27 to version 27
  // Adds video wallpaper settings, Steam integration flags, and lock screen video controls
  function migrate(adapter, logger) {
    logger.i("Settings", "Migrating settings to v27");

    if (adapter.wallpaper !== undefined) {
      if (adapter.wallpaper.videoPlaybackEnabled === undefined) {
        adapter.wallpaper.videoPlaybackEnabled = true;
      }
      if (adapter.wallpaper.videoAudioMuted === undefined) {
        adapter.wallpaper.videoAudioMuted = false;
      }
      if (adapter.wallpaper.videoAudioVolume === undefined) {
        adapter.wallpaper.videoAudioVolume = 0.35;
      }
      // Force per-monitor audio mode for wallpapers
      adapter.wallpaper.videoAudioMode = "per_monitor";

      if (adapter.wallpaper.pauseVideoOnWindows === undefined) {
        adapter.wallpaper.pauseVideoOnWindows = false;
      }
      if (adapter.wallpaper.muteInsteadOfPauseOnWindows === undefined) {
        adapter.wallpaper.muteInsteadOfPauseOnWindows = false;
      }
      if (adapter.wallpaper.pauseVideoOnWindowsMuteWhitelist === undefined) {
        adapter.wallpaper.pauseVideoOnWindowsMuteWhitelist = [];
      }
      if (adapter.wallpaper.pauseVideoOnWindowsBlacklist === undefined) {
        adapter.wallpaper.pauseVideoOnWindowsBlacklist = [];
      }
      if (adapter.wallpaper.steamWallpaperIntegration === undefined) {
        adapter.wallpaper.steamWallpaperIntegration = false;
      }
      if (adapter.wallpaper.useSteamWallpapers === undefined) {
        adapter.wallpaper.useSteamWallpapers = false;
      }
      if (adapter.wallpaper.lockScreenVideoEnabled === undefined) {
        adapter.wallpaper.lockScreenVideoEnabled = true;
      }
      if (adapter.wallpaper.lockScreenVideoMuted === undefined) {
        adapter.wallpaper.lockScreenVideoMuted = false;
      }
    }

    return true;
  }
}
