import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI

Variants {
  id: backgroundVariants
  model: Quickshell.screens

  delegate: Loader {

    required property ShellScreen modelData

    active: modelData && Settings.data.wallpaper.enabled

    sourceComponent: PanelWindow {
      id: root

      // Internal state management
      property string transitionType: "fade"
      property real transitionProgress: 0
      property bool isStartupTransition: true
      property string currentWallpaperPath: ""
      property string currentWallpaperType: "image"
      property string nextWallpaperType: "image"
      property string pendingFallbackPath: ""
      property bool wallpaperSuspended: false
      property bool wallpaperMuteForWindows: false
      property bool wallpaperMuteForLockScreen: false
      property bool isPrimaryScreen: false
      property bool lockScreenActive: PanelService.lockScreen ? PanelService.lockScreen.active : false

      readonly property real edgeSmoothness: Settings.data.wallpaper.transitionEdgeSmoothness
      readonly property var allTransitions: WallpaperService.allTransitions
      readonly property bool transitioning: transitionAnimation.running || fallbackTransitionAnimation.running
      readonly property bool useShaderTransitions: currentWallpaperType === "image" && nextWallpaperType === "image"
      property bool fallbackTransitioning: false
      property bool keepFallbackVisible: false
      readonly property bool fallbackTransitionActive: !useShaderTransitions && fallbackTransitioning

      // Wipe direction: 0=left, 1=right, 2=up, 3=down
      property real wipeDirection: 0

      // Disc
      property real discCenterX: 0.5
      property real discCenterY: 0.5

      // Stripe
      property real stripesCount: 16
      property real stripesAngle: 0

      // Used to debounce wallpaper changes
      property string futureWallpaper: ""
      // Render source that respects playback settings (may differ from futureWallpaper for videos)
      property string futureWallpaperDisplay: ""

      // Fillmode default is "crop"
      property real fillMode: WallpaperService.getFillModeUniform()
      property vector4d fillColor: Qt.vector4d(Settings.data.wallpaper.fillColor.r, Settings.data.wallpaper.fillColor.g, Settings.data.wallpaper.fillColor.b, 1.0)

      Component.onCompleted: setWallpaperInitial()

      Component.onDestruction: {
        transitionAnimation.stop();
        debounceTimer.stop();
        shaderLoader.active = false;
        currentWallpaper.source = "";
        nextWallpaper.source = "";
      }

      Connections {
        target: Settings.data.wallpaper
        function onFillModeChanged() {
          fillMode = WallpaperService.getFillModeUniform();
        }
        function onVideoPlaybackEnabledChanged() {
          futureWallpaperDisplay = getDisplaySource(futureWallpaper);
          setWallpaperImmediate(futureWallpaperDisplay);
          updateWallpaperSuspension();
        }
        function onPauseVideoOnWindowsChanged() {
          updateWallpaperSuspension();
        }
        function onMuteInsteadOfPauseOnWindowsChanged() {
          updateWallpaperSuspension();
        }
        function onPauseVideoOnWindowsMuteWhitelistChanged() {
          updateWallpaperSuspension();
        }
        function onPauseVideoOnWindowsBlacklistChanged() {
          updateWallpaperSuspension();
        }
        function onLockscreenVideoModeChanged() {
          updateWallpaperSuspension();
        }
        function onVideoAudioModeChanged() {
          updatePlaybackState();
        }
      }

      // External state management
      Connections {
        target: WallpaperService
        function onWallpaperChanged(screenName, path) {
          if (screenName === modelData.name) {
            // Update wallpaper display
            // Set wallpaper immediately on startup
            futureWallpaper = path;
            futureWallpaperDisplay = getDisplaySource(path);
            debounceTimer.restart();
          }
        }
        function onWallpaperPreviewReady(originalPath, previewPath) {
          if (!Settings.data.wallpaper.videoPlaybackEnabled) {
            if (futureWallpaper === originalPath) {
              futureWallpaperDisplay = getDisplaySource(originalPath);
              setWallpaperImmediate(futureWallpaperDisplay);
            }
          }
        }
      }

      Connections {
        target: CompositorService
        function onDisplayScalesChanged() {
          // Recalculate image sizes without interrupting startup transition
          if (isStartupTransition) {
            return;
          }
          recalculateImageSizes();
        }
        function onWindowListChanged() {
          updateWallpaperSuspension();
        }
        function onActiveWindowChanged() {
          updateWallpaperSuspension();
        }
        function onWorkspaceChanged() {
          updateWallpaperSuspension();
        }
      }

      Connections {
        target: PanelService.lockScreen
        function onActiveChanged() {
          lockScreenActive = PanelService.lockScreen && PanelService.lockScreen.active;
          updateWallpaperSuspension();
        }
      }

      color: Color.transparent
      screen: modelData
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "noctalia-wallpaper-" + (screen?.name || "unknown")

      anchors {
        bottom: true
        top: true
        right: true
        left: true
      }

      Timer {
        id: debounceTimer
        interval: 333
        running: false
        repeat: false
        onTriggered: {
          changeWallpaper();
        }
      }

      Image {
        id: currentWallpaper

        property bool dimensionsCalculated: false

        source: ""
        smooth: true
        mipmap: false
        visible: false
        cache: false
        asynchronous: true
        sourceSize: undefined
        onStatusChanged: {
          if (status === Image.Error) {
            Logger.w("Current wallpaper failed to load:", source);
          } else if (status === Image.Ready && !dimensionsCalculated) {
            dimensionsCalculated = true;
            const optimalSize = calculateOptimalWallpaperSize(implicitWidth, implicitHeight);
            if (optimalSize !== false) {
              sourceSize = optimalSize;
            }
          }
          if (status === Image.Ready && keepFallbackVisible) {
            keepFallbackVisible = false;
          }
        }
        onSourceChanged: {
          dimensionsCalculated = false;
          sourceSize = undefined;
        }
      }

      Image {
        id: nextWallpaper

        property bool dimensionsCalculated: false

        source: ""
        smooth: true
        mipmap: false
        visible: false
        cache: false
        asynchronous: true
        sourceSize: undefined
        onStatusChanged: {
          if (status === Image.Error) {
            Logger.w("Next wallpaper failed to load:", source);
          } else if (status === Image.Ready && !dimensionsCalculated) {
            dimensionsCalculated = true;
            const optimalSize = calculateOptimalWallpaperSize(implicitWidth, implicitHeight);
            if (optimalSize !== false) {
              sourceSize = optimalSize;
            }
          }
        }
        onSourceChanged: {
          dimensionsCalculated = false;
          sourceSize = undefined;
        }
      }

      // Dynamic shader loader - only loads the active transition shader
      Loader {
        id: shaderLoader
        anchors.fill: parent
        z: 2
        active: (useShaderTransitions && !keepFallbackVisible) || fallbackTransitionActive
        visible: active

        sourceComponent: {
          switch (transitionType) {
          case "wipe":
            return wipeShaderComponent;
          case "disc":
            return discShaderComponent;
          case "stripes":
            return stripesShaderComponent;
          case "fade":
          case "none":
          default:
            return fadeShaderComponent;
          }
        }
      }

      // Fallback renderer for video wallpapers or mixed transitions
      Rectangle {
        id: fallbackFill
        anchors.fill: parent
        color: Qt.rgba(fillColor.x, fillColor.y, fillColor.z, fillColor.w)
        visible: !useShaderTransitions || keepFallbackVisible
      }

      Item {
        id: fallbackContainer
        anchors.fill: parent
        visible: !useShaderTransitions || keepFallbackVisible

        Loader {
          id: fallbackCurrent
          anchors.fill: parent
          active: false
          opacity: 1.0
        }

        Loader {
          id: fallbackNext
          anchors.fill: parent
          active: false
          opacity: 0.0
        }
      }

      property var fallbackBaseLoader: fallbackCurrent
      property var fallbackOverlayLoader: fallbackNext

      ShaderEffectSource {
        id: fallbackBaseSource
        anchors.fill: parent
        sourceItem: fallbackBaseLoader
        live: true
        recursive: true
        hideSource: fallbackTransitionActive
        visible: false
      }

      ShaderEffectSource {
        id: fallbackOverlaySource
        anchors.fill: parent
        sourceItem: fallbackOverlayLoader
        live: true
        recursive: true
        hideSource: fallbackTransitionActive
        visible: false
      }

      readonly property var shaderSource1: useShaderTransitions ? currentWallpaper : fallbackBaseSource
      readonly property var shaderSource2: {
        if (!useShaderTransitions && !fallbackTransitionActive) {
          return shaderSource1;
        }
        return useShaderTransitions ? nextWallpaper : fallbackOverlaySource;
      }
      readonly property real shaderFillMode: useShaderTransitions ? fillMode : 3.0
      readonly property real shaderImageWidth1: getShaderSourceWidth(shaderSource1)
      readonly property real shaderImageHeight1: getShaderSourceHeight(shaderSource1)
      readonly property real shaderImageWidth2: getShaderSourceWidth(shaderSource2)
      readonly property real shaderImageHeight2: getShaderSourceHeight(shaderSource2)

      // Fade or None transition shader component
      Component {
        id: fadeShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: root.shaderSource1
          property variant source2: root.shaderSource2
          property real progress: root.transitionProgress

          // Fill mode properties
          property real fillMode: root.shaderFillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: root.shaderImageWidth1
          property real imageHeight1: root.shaderImageHeight1
          property real imageWidth2: root.shaderImageWidth2
          property real imageHeight2: root.shaderImageHeight2
          property real screenWidth: width
          property real screenHeight: height

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_fade.frag.qsb")
        }
      }

      // Wipe transition shader component
      Component {
        id: wipeShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: root.shaderSource1
          property variant source2: root.shaderSource2
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real direction: root.wipeDirection

          // Fill mode properties
          property real fillMode: root.shaderFillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: root.shaderImageWidth1
          property real imageHeight1: root.shaderImageHeight1
          property real imageWidth2: root.shaderImageWidth2
          property real imageHeight2: root.shaderImageHeight2
          property real screenWidth: width
          property real screenHeight: height

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_wipe.frag.qsb")
        }
      }

      // Disc reveal transition shader component
      Component {
        id: discShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: root.shaderSource1
          property variant source2: root.shaderSource2
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real aspectRatio: root.width / root.height
          property real centerX: root.discCenterX
          property real centerY: root.discCenterY

          // Fill mode properties
          property real fillMode: root.shaderFillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: root.shaderImageWidth1
          property real imageHeight1: root.shaderImageHeight1
          property real imageWidth2: root.shaderImageWidth2
          property real imageHeight2: root.shaderImageHeight2
          property real screenWidth: width
          property real screenHeight: height

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_disc.frag.qsb")
        }
      }

      // Diagonal stripes transition shader component
      Component {
        id: stripesShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: root.shaderSource1
          property variant source2: root.shaderSource2
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real aspectRatio: root.width / root.height
          property real stripeCount: root.stripesCount
          property real angle: root.stripesAngle

          // Fill mode properties
          property real fillMode: root.shaderFillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: root.shaderImageWidth1
          property real imageHeight1: root.shaderImageHeight1
          property real imageWidth2: root.shaderImageWidth2
          property real imageHeight2: root.shaderImageHeight2
          property real screenWidth: width
          property real screenHeight: height

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_stripes.frag.qsb")
        }
      }

      // Components for fallback rendering (image/video)
      Component {
        id: wallpaperImageComponent
        Image {
          id: fallbackImage
          anchors.fill: parent
          property string wallpaperPath: ""
          source: wallpaperPath
          fillMode: root.imageFillMode()
          smooth: true
          cache: false
          asynchronous: true
          mipmap: false
        }
      }

      Component {
        id: wallpaperVideoComponent
        Item {
          id: fallbackVideo
          anchors.fill: parent
          property string wallpaperPath: ""
          property bool suspended: false
          property bool shouldPlay: false
          property real targetVolume: 0.0
          property string pendingPath: ""
          property bool fadeSwitching: false
          readonly property int fadeDuration: Math.max(120, Settings.data.wallpaper.transitionDuration)

          Behavior on targetVolume {
            NumberAnimation {
              duration: fadeDuration
              easing.type: Easing.InOutCubic
            }
          }

          Timer {
            id: fadeOutTimer
            interval: fadeDuration
            repeat: false
            onTriggered: {
              videoPlayer.pause();
              WallpaperService.clearActiveAudioPath(videoPlayer.source);
              if (fadeSwitching && pendingPath !== "") {
                fadeSwitching = false;
                videoPlayer.source = pendingPath;
                pendingPath = "";
                updatePlaybackState();
              }
            }
          }

          function updatePlaybackState() {
            shouldPlay = Settings.data.wallpaper.videoPlaybackEnabled && !suspended && wallpaperPath;

            const audioMode = Settings.data.wallpaper.videoAudioMode || "per_monitor";
            const primaryMonitor = WallpaperService.getPrimaryAudioMonitor();
            isPrimaryScreen = primaryMonitor && (primaryMonitor === (root.screen?.name || ""));

            if (shouldPlay) {
              fadeOutTimer.stop();
              if (audioMode === "primary") {
                if (isPrimaryScreen) {
                  WallpaperService.setActiveAudioPath(wallpaperPath);
                } else {
                  WallpaperService.clearActiveAudioPath(wallpaperPath);
                }
              } else {
                WallpaperService.clearActiveAudioPath(wallpaperPath);
              }
              videoPlayer.play();
            } else {
              targetVolume = 0.0;
              fadeOutTimer.restart();
            }
            videoSurface.visible = wallpaperPath !== "";
            updateVolume();
          }

          function updateVolume() {
            const baseVolume = Settings.data.wallpaper.videoAudioVolume;
            const hasFocus = WallpaperService.activeAudioPath === wallpaperPath;
            const muted = WallpaperService.computeAudioMuted() || root.wallpaperMuteForWindows || root.wallpaperMuteForLockScreen;
            const audioMode = Settings.data.wallpaper.videoAudioMode || "per_monitor";

            var desired = 0.0;
            if (shouldPlay && !muted) {
              if (audioMode === "per_monitor") {
                desired = baseVolume;
              } else if (audioMode === "primary" && isPrimaryScreen && hasFocus) {
                desired = baseVolume;
              }
            }
            targetVolume = desired;
          }

          MediaPlayer {
            id: videoPlayer
            source: wallpaperPath
            loops: MediaPlayer.Infinite
            autoPlay: false
            videoOutput: videoSurface
            audioOutput: AudioOutput {
              muted: WallpaperService.computeAudioMuted()
              volume: fallbackVideo.targetVolume
            }
          }

          VideoOutput {
            id: videoSurface
            anchors.fill: parent
            fillMode: root.videoFillMode()
            visible: wallpaperPath !== ""
          }

          onWallpaperPathChanged: {
            fadeOutTimer.stop();
            if (videoPlayer.playbackState === MediaPlayer.PlayingState
                && videoPlayer.source
                && wallpaperPath !== videoPlayer.source) {
              pendingPath = wallpaperPath;
              fadeSwitching = true;
              targetVolume = 0.0;
              fadeOutTimer.restart();
              return;
            }
            WallpaperService.clearActiveAudioPath(videoPlayer.source);
            videoPlayer.source = wallpaperPath;
            updatePlaybackState();
          }

          onSuspendedChanged: updatePlaybackState()
          Component.onDestruction: WallpaperService.clearActiveAudioPath(videoPlayer.source)
          Component.onCompleted: updatePlaybackState()

          Connections {
            target: Settings.data.wallpaper
            function onVideoAudioVolumeChanged() { updateVolume(); }
            function onVideoAudioMutedChanged() { updateVolume(); }
            function onVideoPlaybackEnabledChanged() { updatePlaybackState(); }
            function onVideoAudioModeChanged() { updatePlaybackState(); }
          }
          Connections {
            target: WallpaperService
            function onAudioFocusChanged() { updateVolume(); }
          }
        }
      }

      // Animation for the transition progress
      NumberAnimation {
        id: transitionAnimation
        target: root
        property: "transitionProgress"
        from: 0.0
        to: 1.0
        // The stripes shader feels faster visually, we make it a bit slower here.
        duration: transitionType == "stripes" ? Settings.data.wallpaper.transitionDuration * 1.6 : Settings.data.wallpaper.transitionDuration
        easing.type: Easing.InOutCubic
        onFinished: {
          if (!useShaderTransitions) {
            transitionProgress = 0.0;
            return;
          }
          // Assign new image to current BEFORE clearing to prevent flicker
          const tempSource = nextWallpaper.source;
          currentWallpaper.source = tempSource;
          currentWallpaperPath = tempSource;
          currentWallpaperType = nextWallpaperType;
          transitionProgress = 0.0;

          // Now clear nextWallpaper after currentWallpaper has the new source
          // Force complete cleanup to free texture memory (~18-25MB per monitor)
          Qt.callLater(() => {
                         nextWallpaper.source = "";
                         nextWallpaper.sourceSize = undefined;
                         Qt.callLater(() => {
                                       currentWallpaper.asynchronous = true;
                                     });
                       });
        }
      }

      // Simple crossfade animation used when a video wallpaper is involved
      NumberAnimation {
        id: fallbackTransitionAnimation
        target: root
        property: "transitionProgress"
        from: 0.0
        to: 1.0
        duration: Settings.data.wallpaper.transitionDuration
        easing.type: Easing.InOutCubic
        onFinished: finalizeFallbackTransition()
      }

      // ------------------------------------------------------
      function calculateOptimalWallpaperSize(wpWidth, wpHeight) {
        const compositorScale = CompositorService.getDisplayScale(modelData.name);
        const screenWidth = modelData.width * compositorScale;
        const screenHeight = modelData.height * compositorScale;
        if (wpWidth <= screenWidth || wpHeight <= screenHeight || wpWidth <= 0 || wpHeight <= 0) {
          // Do not resize if wallpaper is smaller than one of the screen dimension
          return;
        }

        const imageAspectRatio = wpWidth / wpHeight;
        var dim = Qt.size(0, 0);
        if (screenWidth >= screenHeight) {
          const w = Math.min(screenWidth, wpWidth);
          dim = Qt.size(Math.round(w), Math.round(w / imageAspectRatio));
        } else {
          const h = Math.min(screenHeight, wpHeight);
          dim = Qt.size(Math.round(h * imageAspectRatio), Math.round(h));
        }

        Logger.d("Background", `Wallpaper resized on ${modelData.name} ${screenWidth}x${screenHeight} @ ${compositorScale}x`, "src:", wpWidth, wpHeight, "dst:", dim.width, dim.height);
        return dim;
      }

      // ------------------------------------------------------
      function recalculateImageSizes() {
        // Re-evaluate and apply optimal sourceSize for both images when ready
        if (currentWallpaper.status === Image.Ready) {
          const optimal = calculateOptimalWallpaperSize(currentWallpaper.implicitWidth, currentWallpaper.implicitHeight);
          if (optimal !== undefined && optimal !== false) {
            currentWallpaper.sourceSize = optimal;
          } else {
            currentWallpaper.sourceSize = undefined;
          }
        }

        if (nextWallpaper.status === Image.Ready) {
          const optimal2 = calculateOptimalWallpaperSize(nextWallpaper.implicitWidth, nextWallpaper.implicitHeight);
          if (optimal2 !== undefined && optimal2 !== false) {
            nextWallpaper.sourceSize = optimal2;
          } else {
            nextWallpaper.sourceSize = undefined;
          }
        }
      }

      function imageFillMode() {
        switch (Settings.data.wallpaper.fillMode) {
        case "center":
          return Image.Pad;
        case "fit":
          return Image.PreserveAspectFit;
        case "stretch":
          return Image.Stretch;
        case "crop":
        default:
          return Image.PreserveAspectCrop;
        }
      }

      function videoFillMode() {
        switch (Settings.data.wallpaper.fillMode) {
        case "center":
          return VideoOutput.PreserveAspectFit;
        case "fit":
          return VideoOutput.PreserveAspectFit;
        case "stretch":
          return VideoOutput.Stretch;
        case "crop":
        default:
          return VideoOutput.PreserveAspectCrop;
        }
      }

      function getShaderSourceWidth(source) {
        if (!source) {
          return width;
        }
        if (source.sourceSize && source.sourceSize.width > 0) {
          return source.sourceSize.width;
        }
        if (source.width && source.width > 0) {
          return source.width;
        }
        if (source.implicitWidth && source.implicitWidth > 0) {
          return source.implicitWidth;
        }
        if (source.item && source.item.width > 0) {
          return source.item.width;
        }
        if (source.item && source.item.implicitWidth > 0) {
          return source.item.implicitWidth;
        }
        return width;
      }

      function getShaderSourceHeight(source) {
        if (!source) {
          return height;
        }
        if (source.sourceSize && source.sourceSize.height > 0) {
          return source.sourceSize.height;
        }
        if (source.height && source.height > 0) {
          return source.height;
        }
        if (source.implicitHeight && source.implicitHeight > 0) {
          return source.implicitHeight;
        }
        if (source.item && source.item.height > 0) {
          return source.item.height;
        }
        if (source.item && source.item.implicitHeight > 0) {
          return source.item.implicitHeight;
        }
        return height;
      }

      function getActiveWorkspacesForScreen(screenName) {
        const activeIds = [];
        if (!CompositorService || !CompositorService.workspaces) {
          return activeIds;
        }
        for (var i = 0; i < CompositorService.workspaces.count; i++) {
          const ws = CompositorService.workspaces.get(i);
          if (ws.output === screenName && (ws.isActive || ws.isFocused)) {
            activeIds.push(String(ws.id));
          }
        }
        return activeIds;
      }

      function windowMatchesList(list, window) {
        if (!list || list.length === 0) {
          return false;
        }
        const haystack = [
          window?.appId,
          window?.class,
          window?.initialClass,
          window?.title,
          window?.name
        ].filter(Boolean).map(x => String(x).toLowerCase()).join(" ");

        for (var i = 0; i < list.length; i++) {
          const term = String(list[i] || "").toLowerCase().trim();
          if (term.length > 0 && haystack.includes(term)) {
            return true;
          }
        }
        return false;
      }

      function isWindowBlacklisted(window) {
        return windowMatchesList(Settings.data.wallpaper.pauseVideoOnWindowsBlacklist || [], window);
      }

      function isWindowMuteWhitelisted(window) {
        return windowMatchesList(Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist || [], window);
      }

      function computeWindowActions() {
        const actions = {
          pause: false,
          mute: false
        };

        if (!Settings.data.wallpaper.videoPlaybackEnabled || !Settings.data.wallpaper.pauseVideoOnWindows) {
          return actions;
        }

        const screenName = modelData?.name;
        if (!screenName || !CompositorService || !CompositorService.windows) {
          return actions;
        }

        const activeWorkspaceIds = getActiveWorkspacesForScreen(screenName);
        const muteEnabled = Settings.data.wallpaper.muteInsteadOfPauseOnWindows;
        const whitelist = Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist || [];
        const whitelistActive = muteEnabled && whitelist.length > 0;

        // If mute-instead is on and whitelist is empty, treat every window as mute-only (no pause)
        if (muteEnabled && !whitelistActive) {
          for (var j = 0; j < CompositorService.windows.count; j++) {
            const w = CompositorService.windows.get(j);
            if (isWindowBlacklisted(w)) {
              continue;
            }
            const wWorkspace = (w.workspaceId !== undefined && w.workspaceId !== null) ? String(w.workspaceId) : "";
            const onScreen = (activeWorkspaceIds.length > 0 && activeWorkspaceIds.indexOf(wWorkspace) !== -1)
                             || (activeWorkspaceIds.length === 0 && w.output === screenName);
            if (onScreen) {
              actions.mute = true;
              break;
            }
          }
          return actions;
        }

        for (var i = 0; i < CompositorService.windows.count; i++) {
          const window = CompositorService.windows.get(i);
          if (isWindowBlacklisted(window)) {
            continue;
          }
          const windowWorkspace = (window.workspaceId !== undefined && window.workspaceId !== null) ? String(window.workspaceId) : "";
          const isOnScreen = (activeWorkspaceIds.length > 0 && activeWorkspaceIds.indexOf(windowWorkspace) !== -1)
                             || (activeWorkspaceIds.length === 0 && window.output === screenName);
          if (!isOnScreen) {
            continue;
          }

          const whitelistedForMute = whitelistActive && isWindowMuteWhitelisted(window);
          const windowTriggersMute = muteEnabled && (!whitelistActive || whitelistedForMute);
          const windowTriggersPause = (!muteEnabled) || (whitelistActive && !whitelistedForMute);

          actions.mute = actions.mute || windowTriggersMute;
          actions.pause = actions.pause || windowTriggersPause;

          if (actions.mute && actions.pause) {
            break;
          }
        }

        return actions;
      }

      function applySuspensionToLoader(loader) {
        if (loader && loader.item && loader.item.hasOwnProperty("suspended")) {
          loader.item.suspended = wallpaperSuspended;
        }
      }

      function fadeOutLoaderAudio(loader) {
        if (loader && loader.item && loader.item.hasOwnProperty("targetVolume")) {
          loader.item.targetVolume = 0.0;
        }
      }

      function refreshWallpaperAudio() {
        const loaders = [fallbackBaseLoader, fallbackOverlayLoader];
        for (var i = 0; i < loaders.length; i++) {
          var item = loaders[i]?.item;
          if (item && item.updateVolume) {
            item.updateVolume();
          }
        }
      }

      function syncVideoSuspension() {
        applySuspensionToLoader(fallbackBaseLoader);
        applySuspensionToLoader(fallbackOverlayLoader);
      }

      function updateWallpaperSuspension() {
        const actions = computeWindowActions();
        let shouldSuspend = actions.pause;
        let shouldMute = actions.mute;
        let shouldMuteLockScreen = false;

        // Check lock screen state
        if (lockScreenActive) {
          const lockMode = Settings.data.wallpaper.lockscreenVideoMode || "muted";
          if (lockMode === "disabled") {
            shouldSuspend = true;
          } else if (lockMode === "muted") {
            shouldMuteLockScreen = true;
          }
          // If mode is "normal", don't change anything
        }

        if (wallpaperSuspended === shouldSuspend && 
            wallpaperMuteForWindows === shouldMute &&
            wallpaperMuteForLockScreen === shouldMuteLockScreen) {
          return;
        }

        wallpaperSuspended = shouldSuspend;
        wallpaperMuteForWindows = shouldMute;
        wallpaperMuteForLockScreen = shouldMuteLockScreen;
        syncVideoSuspension();
        refreshWallpaperAudio();
      }

      onWallpaperSuspendedChanged: syncVideoSuspension()

      // ------------------------------------------------------
      function setFallbackVisual(loader, path, type) {
        if (!loader) {
          return;
        }
        if (!path) {
          loader.active = false;
          loader.sourceComponent = null;
          return;
        }

        loader.sourceComponent = (type === "video") ? wallpaperVideoComponent : wallpaperImageComponent;
        loader.active = true;

        if (loader.item) {
          loader.item.wallpaperPath = path;
          applySuspensionToLoader(loader);
        } else {
          // Apply the source after creation
          Qt.callLater(() => {
                         if (loader.item) {
                           loader.item.wallpaperPath = path;
                           applySuspensionToLoader(loader);
                         }
                       });
        }
      }

      function finalizeFallbackTransition() {
        fallbackTransitionAnimation.stop();

        if (!pendingFallbackPath) {
          fallbackTransitioning = false;
          return;
        }

        currentWallpaperPath = pendingFallbackPath;
        currentWallpaperType = nextWallpaperType;

        if (currentWallpaperType === "image") {
          keepFallbackVisible = true;
          currentWallpaper.source = currentWallpaperPath;
        }

        // Swap loaders so the overlay becomes the new base and reuse its video/player
        var oldBase = fallbackBaseLoader;
        fallbackBaseLoader = fallbackOverlayLoader;
        fallbackOverlayLoader = oldBase;

        fallbackBaseLoader.opacity = 1.0;
        fallbackOverlayLoader.opacity = 0.0;
        fallbackOverlayLoader.active = false;
        fallbackOverlayLoader.sourceComponent = null;

        pendingFallbackPath = "";
        transitionProgress = 0.0;
        fallbackTransitioning = false;
        if (!useShaderTransitions) {
          keepFallbackVisible = false;
        }
      }

      // ------------------------------------------------------
      function setWallpaperInitial() {
        // On startup, defer assigning wallpaper until the service cache is ready, retries every tick
        if (!WallpaperService || !WallpaperService.isInitialized) {
          Qt.callLater(setWallpaperInitial);
          return;
        }

        const wallpaperPath = WallpaperService.getWallpaper(modelData.name);

        futureWallpaper = wallpaperPath;
        performStartupTransition();
        Qt.callLater(updateWallpaperSuspension);
      }

      // ------------------------------------------------------
      function setWallpaperImmediate(source) {
        transitionAnimation.stop();
        fallbackTransitionAnimation.stop();
        transitionProgress = 0.0;
        fallbackTransitioning = false;
        keepFallbackVisible = false;

        // Clear nextWallpaper completely to free texture memory
        nextWallpaper.source = "";
        nextWallpaper.sourceSize = undefined;

        currentWallpaper.source = "";
        pendingFallbackPath = "";

        const nextType = WallpaperService.getWallpaperType(source);
        nextWallpaperType = nextType;
        currentWallpaperType = nextType;
        currentWallpaperPath = source;

        if (nextType === "image") {
          fallbackBaseLoader.active = false;
          fallbackOverlayLoader.active = false;
          fallbackOverlayLoader.opacity = 0.0;
          Qt.callLater(() => {
                         currentWallpaper.source = source;
                       });
        } else {
          setFallbackVisual(fallbackBaseLoader, source, nextType);
          fallbackOverlayLoader.active = false;
          fallbackOverlayLoader.opacity = 0.0;
        }
      }

      // ------------------------------------------------------
      function setWallpaperWithTransition(source) {
        if (source === currentWallpaper.source && currentWallpaperType === "image") {
          return;
        }
        const nextType = WallpaperService.getWallpaperType(source);
        nextWallpaperType = nextType;
        if (source === currentWallpaperPath && currentWallpaperType === nextType) {
          return;
        }

        if (transitioning) {
          // We are interrupting a transition - handle cleanup properly
          transitionAnimation.stop();
          fallbackTransitionAnimation.stop();
          transitionProgress = 0;

          if (pendingFallbackPath) {
            finalizeFallbackTransition();
          }

          if (useShaderTransitions) {
            // Assign nextWallpaper to currentWallpaper BEFORE clearing to prevent flicker
            const newCurrentSource = nextWallpaper.source;
            currentWallpaper.source = newCurrentSource;

            // Now clear nextWallpaper after current has the new source
            Qt.callLater(() => {
                          nextWallpaper.source = "";

                          // Now set the next wallpaper after a brief delay
                          Qt.callLater(() => {
                                         nextWallpaper.source = source;
                                         currentWallpaper.asynchronous = false;
                                        transitionAnimation.start();
                                       });
                        });
          } else {
            // Restart fallback transition with the new sources
            currentWallpaper.asynchronous = true;
            setFallbackVisual(fallbackBaseLoader, currentWallpaperPath || currentWallpaper.source || source, currentWallpaperType);
            setFallbackVisual(fallbackOverlayLoader, source, nextType);
            fallbackOverlayLoader.opacity = 0.0;
            pendingFallbackPath = source;
            fallbackTransitioning = true;

            // Fade audio out on the old wallpaper while the new one fades in
            fadeOutLoaderAudio(fallbackBaseLoader);

            var durationInterrupt = Settings.data.wallpaper.transitionDuration;
            if (transitionType === "stripes") {
              durationInterrupt = Settings.data.wallpaper.transitionDuration * 1.6;
            }
            transitionProgress = 0.0;
            fallbackTransitionAnimation.duration = durationInterrupt;
            fallbackTransitionAnimation.start();
          }
          return;
        }

        if (currentWallpaperType === "image" && nextType === "image") {
          pendingFallbackPath = "";
          nextWallpaper.source = source;
          currentWallpaper.asynchronous = false;
          keepFallbackVisible = false;
          transitionAnimation.start();
          return;
        }

        // Fallback: crossfade when video is involved
        transitionAnimation.stop();
        currentWallpaper.asynchronous = true;

        // When starting from no wallpaper, just set immediately
        if (!currentWallpaperPath) {
          setWallpaperImmediate(source);
          return;
        }

        // Ensure the current fallback visual represents the active wallpaper
        setFallbackVisual(fallbackBaseLoader, currentWallpaperPath || currentWallpaper.source || source, currentWallpaperType);
        setFallbackVisual(fallbackOverlayLoader, source, nextType);
        fallbackOverlayLoader.opacity = 0.0;

        // Fade audio out on the old wallpaper while the new one fades in
        fadeOutLoaderAudio(fallbackBaseLoader);

        pendingFallbackPath = source;
        fallbackTransitioning = true;
        keepFallbackVisible = false;

        if (transitionType === "none") {
          finalizeFallbackTransition();
          return;
        } else {
          var duration = Settings.data.wallpaper.transitionDuration;
          if (transitionType === "stripes") {
            duration = Settings.data.wallpaper.transitionDuration * 1.6;
          }
          transitionProgress = 0.0;
          fallbackTransitioning = true;
          fallbackTransitionAnimation.duration = duration;
          fallbackTransitionAnimation.start();
        }
      }

      // ------------------------------------------------------
      // Main method that actually trigger the wallpaper change
      function changeWallpaper() {
        // Get the transitionType from the settings
        transitionType = Settings.data.wallpaper.transitionType;
        futureWallpaperDisplay = getDisplaySource(futureWallpaper);
        nextWallpaperType = WallpaperService.getWallpaperType(futureWallpaperDisplay);

        if (transitionType == "random") {
          var index = Math.floor(Math.random() * allTransitions.length);
          transitionType = allTransitions[index];
        }

        // Ensure the transition type really exists
        if (transitionType !== "none" && !allTransitions.includes(transitionType)) {
          transitionType = "fade";
        }

        //Logger.i("Background", "New wallpaper: ", futureWallpaper, "On:", modelData.name, "Transition:", transitionType)
        switch (transitionType) {
        case "none":
          setWallpaperImmediate(futureWallpaperDisplay);
          break;
        case "wipe":
          wipeDirection = Math.random() * 4;
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        case "disc":
          discCenterX = Math.random();
          discCenterY = Math.random();
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        case "stripes":
          stripesCount = Math.round(Math.random() * 20 + 4);
          stripesAngle = Math.random() * 360;
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        default:
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        }
      }

      // ------------------------------------------------------
      // Dedicated function for startup animation
      function performStartupTransition() {
        // Get the transitionType from the settings
        transitionType = Settings.data.wallpaper.transitionType;
        futureWallpaperDisplay = getDisplaySource(futureWallpaper);
        nextWallpaperType = WallpaperService.getWallpaperType(futureWallpaperDisplay);

        if (transitionType == "random") {
          var index = Math.floor(Math.random() * allTransitions.length);
          transitionType = allTransitions[index];
        }

        // Ensure the transition type really exists
        if (transitionType !== "none" && !allTransitions.includes(transitionType)) {
          transitionType = "fade";
        }

        // Apply transitionType so the shader loader picks the correct shader
        this.transitionType = transitionType;

        switch (transitionType) {
        case "none":
          setWallpaperImmediate(futureWallpaperDisplay);
          break;
        case "wipe":
          wipeDirection = Math.random() * 4;
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        case "disc":
          // Force center origin for elegant startup animation
          discCenterX = 0.5;
          discCenterY = 0.5;
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        case "stripes":
          stripesCount = Math.round(Math.random() * 20 + 4);
          stripesAngle = Math.random() * 360;
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        default:
          setWallpaperWithTransition(futureWallpaperDisplay);
          break;
        }
        // Mark startup transition complete
        isStartupTransition = false;
      }

      // ------------------------------------------------------
      function getDisplaySource(path) {
        if (!path) {
          return "";
        }
        if (!WallpaperService.isVideo(path) || Settings.data.wallpaper.videoPlaybackEnabled) {
          return path;
        }

        // Use generated preview path as static fallback when video playback is disabled
        const previewPath = WallpaperService.buildPreviewPath(path);
        WallpaperService.ensureVideoPreview(path, previewPath);
        return previewPath;
      }
    }
  }
}
