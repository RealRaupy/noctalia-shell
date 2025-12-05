import QtQuick
import Quickshell
import Quickshell.Wayland
import QtMultimedia
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

      readonly property real edgeSmoothness: Settings.data.wallpaper.transitionEdgeSmoothness
      readonly property var allTransitions: WallpaperService.allTransitions
      readonly property bool transitioning: transitionAnimation.running || fallbackTransitionAnimation.running

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
      property string currentWallpaperType: "image"
      property string nextWallpaperType: "image"
      property string currentWallpaperPath: ""
      property bool useFallbackTransition: false
      property real fallbackTransitionProgress: 0
      property bool wallpaperSuspended: false
      property bool wallpaperMuteForWindows: false
      property int imageFillMode: getImageFillMode()
      property int videoFillMode: getVideoFillMode()

      // Fillmode default is "crop"
      property real fillMode: WallpaperService.getFillModeUniform()
      property vector4d fillColor: Qt.vector4d(Settings.data.wallpaper.fillColor.r, Settings.data.wallpaper.fillColor.g, Settings.data.wallpaper.fillColor.b, 1.0)

      Component.onCompleted: setWallpaperInitial()

      Component.onDestruction: {
        transitionAnimation.stop();
        fallbackTransitionAnimation.stop();
        debounceTimer.stop();
        shaderLoader.active = false;
        currentWallpaper.source = "";
        nextWallpaper.source = "";
      }

      onFallbackTransitionProgressChanged: {
        if (currentFallback.item) {
          currentFallback.item.opacity = useFallbackTransition ? 1 - fallbackTransitionProgress : 1;
          if (currentFallback.item.visualOpacity !== undefined) {
            currentFallback.item.visualOpacity = currentFallback.item.opacity;
          }
        }
        if (nextFallback.item) {
          nextFallback.item.opacity = fallbackTransitionProgress;
          if (nextFallback.item.visualOpacity !== undefined) {
            nextFallback.item.visualOpacity = nextFallback.item.opacity;
          }
        }
      }

      Connections {
        target: Settings.data.wallpaper
        function onFillModeChanged() {
          fillMode = WallpaperService.getFillModeUniform();
          imageFillMode = getImageFillMode();
          videoFillMode = getVideoFillMode();
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
        function onVideoPlaybackEnabledChanged() {
          if (currentWallpaperPath !== "" && WallpaperService.isVideoFile(currentWallpaperPath)) {
            futureWallpaper = currentWallpaperPath;
            setWallpaperImmediate(getDisplaySource(currentWallpaperPath));
          }
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
            debounceTimer.restart();
          }
        }
        function onWallpaperPreviewReady(originalPath, previewPath) {
          if (!Settings.data.wallpaper.videoPlaybackEnabled) {
            if (currentWallpaperPath === originalPath && !useFallbackTransition) {
              currentWallpaper.source = "";
              currentWallpaper.source = previewPath;
            }
            if (currentWallpaperPath === originalPath && useFallbackTransition && currentFallback.item && currentFallback.item.setSource) {
              currentFallback.item.setSource("");
              currentFallback.item.setSource(previewPath);
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
        function onWorkspaceChanged() {
          updateWallpaperSuspension();
        }
        function onActiveWindowChanged() {
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
        active: !useFallbackTransition

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

      // Fade or None transition shader component
      Component {
        id: fadeShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
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

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real direction: root.wipeDirection

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
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

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real aspectRatio: root.width / root.height
          property real centerX: root.discCenterX
          property real centerY: root.discCenterY

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
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

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real aspectRatio: root.width / root.height
          property real stripeCount: root.stripesCount
          property real angle: root.stripesAngle

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_stripes.frag.qsb")
        }
      }

      Item {
        id: fallbackLayer
        anchors.fill: parent
        visible: useFallbackTransition

        Loader {
          id: currentFallback
          anchors.fill: parent
          active: useFallbackTransition
        }

        Loader {
          id: nextFallback
          anchors.fill: parent
          active: useFallbackTransition
          opacity: 0
        }
      }

      Component {
        id: fallbackImageComponent
        Image {
          id: fallbackImage
          anchors.fill: parent
          smooth: true
          mipmap: false
          cache: false
          asynchronous: true
          fillMode: root.imageFillMode
          property real visualOpacity: opacity
          function setSource(src) {
            source = src;
          }
        }
      }

      Component {
        id: fallbackVideoComponent
        Item {
          id: fallbackVideo
          anchors.fill: parent

          property string source: ""
          property real visualOpacity: opacity
          property bool suspended: false
          property bool muteForWindows: false
          property string screenName: modelData ? modelData.name : ""
          property bool primaryAudio: Settings.data.wallpaper.videoAudioMode !== "primary" ? true : (screenName === Screen.name)

          MediaPlayer {
            id: mediaPlayer
            source: fallbackVideo.source
            loops: MediaPlayer.Infinite
            videoOutput: videoOutput
            audioOutput: wallpaperAudio
          }

          VideoOutput {
            id: videoOutput
            anchors.fill: parent
            fillMode: root.videoFillMode
          }

          AudioOutput {
            id: wallpaperAudio
            muted: true
            volume: 0
          }

          function updatePlaybackState() {
            if (!Settings.data.wallpaper.videoPlaybackEnabled || suspended) {
              mediaPlayer.pause();
            } else if (mediaPlayer.source) {
              mediaPlayer.play();
            }

            var muted = muteForWindows || suspended || WallpaperService.computeAudioMuted(fallbackVideo.source);
            wallpaperAudio.muted = muted;
            wallpaperAudio.volume = muted ? 0 : Settings.data.wallpaper.videoAudioVolume * visualOpacity;
          }

          function setSource(src) {
            source = src;
            mediaPlayer.source = src;
            if (Settings.data.wallpaper.videoAudioMode === "primary" && primaryAudio) {
              WallpaperService.setActiveAudioPath(src);
            }
            updatePlaybackState();
          }

          onVisualOpacityChanged: updatePlaybackState()
          onMuteForWindowsChanged: updatePlaybackState()
          onSuspendedChanged: updatePlaybackState()

          Connections {
            target: WallpaperService
            function onAudioFocusChanged() {
              fallbackVideo.updatePlaybackState();
            }
          }
          Connections {
            target: Settings.data.wallpaper
            function onVideoPlaybackEnabledChanged() {
              fallbackVideo.updatePlaybackState();
            }
            function onVideoAudioMutedChanged() {
              fallbackVideo.updatePlaybackState();
            }
            function onVideoAudioVolumeChanged() {
              fallbackVideo.updatePlaybackState();
            }
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
          // Assign new image to current BEFORE clearing to prevent flicker
          const tempSource = nextWallpaper.source;
          currentWallpaper.source = tempSource;
          currentWallpaperPath = futureWallpaper;
          currentWallpaperType = nextWallpaperType;
          nextWallpaperType = currentWallpaperType;
          transitionProgress = 0.0;
          useFallbackTransition = (currentWallpaperType === "video");

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

      NumberAnimation {
        id: fallbackTransitionAnimation
        target: root
        property: "fallbackTransitionProgress"
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

      function getDisplaySource(path) {
        if (!path || path === "") {
          return "";
        }
        if (WallpaperService.isVideoFile(path) && !Settings.data.wallpaper.videoPlaybackEnabled) {
          WallpaperService.generateWallpaperPreview(path);
          return WallpaperService.getPreviewPath(path);
        }
        return path;
      }

      function getFallbackComponent(type) {
        if (type === "video" && Settings.data.wallpaper.videoPlaybackEnabled) {
          return fallbackVideoComponent;
        }
        return fallbackImageComponent;
      }

      function getImageFillMode() {
        switch (Settings.data.wallpaper.fillMode) {
        case "fit":
          return Image.PreserveAspectFit;
        case "stretch":
          return Image.Stretch;
        case "center":
          return Image.Pad;
        default:
          return Image.PreserveAspectCrop;
        }
      }

      function getVideoFillMode() {
        switch (Settings.data.wallpaper.fillMode) {
        case "fit":
          return VideoOutput.PreserveAspectFit;
        case "stretch":
          return VideoOutput.Stretch;
        case "center":
          return VideoOutput.Pad;
        default:
          return VideoOutput.PreserveAspectCrop;
        }
      }

      function matchesWindowRule(win, rules) {
        if (!rules || !rules.length) {
          return false;
        }
        var appId = (win.appId || "").toString().toLowerCase();
        var cls = (win.class || "").toString().toLowerCase();
        var title = (win.title || "").toString().toLowerCase();
        var name = (win.name || "").toString().toLowerCase();
        for (var i = 0; i < rules.length; i++) {
          var rule = (rules[i] || "").toString().toLowerCase();
          if (rule === "") {
            continue;
          }
          if ((appId && appId.indexOf(rule) !== -1) || (cls && cls.indexOf(rule) !== -1) || (title && title.indexOf(rule) !== -1) || (name && name.indexOf(rule) !== -1)) {
            return true;
          }
        }
        return false;
      }

      function updateWallpaperSuspension() {
        if (!Settings.data.wallpaper.pauseVideoOnWindows) {
          wallpaperSuspended = false;
          wallpaperMuteForWindows = false;
          applySuspensionState();
          return;
        }

        var targetWorkspaceId = -1;
        var fallbackWorkspaceId = -1;
        for (var i = 0; i < CompositorService.workspaces.count; i++) {
          var ws = CompositorService.workspaces.get(i);
          if (ws.output !== modelData.name) {
            continue;
          }
          if (ws.isFocused || ws.isActive) {
            targetWorkspaceId = ws.id;
            break;
          }
          if (fallbackWorkspaceId === -1) {
            fallbackWorkspaceId = ws.id;
          }
        }
        if (targetWorkspaceId === -1) {
          targetWorkspaceId = fallbackWorkspaceId;
        }

        var windows = CompositorService.windows;
        var shouldBlock = false;

        for (var w = 0; w < windows.count; w++) {
          var win = windows.get(w);
          var sameWorkspace = targetWorkspaceId !== -1 && win.workspaceId === targetWorkspaceId;
          var sameOutput = win.output && win.output === modelData.name;
          if (targetWorkspaceId !== -1) {
            if (!sameWorkspace) {
              continue;
            }
          } else if (!sameOutput) {
            continue;
          }

          if (matchesWindowRule(win, Settings.data.wallpaper.pauseVideoOnWindowsMuteWhitelist)) {
            continue;
          }
          if (matchesWindowRule(win, Settings.data.wallpaper.pauseVideoOnWindowsBlacklist)) {
            continue;
          }
          shouldBlock = true;
          break;
        }

        if (!shouldBlock) {
          wallpaperSuspended = false;
          wallpaperMuteForWindows = false;
        } else if (Settings.data.wallpaper.muteInsteadOfPauseOnWindows) {
          wallpaperSuspended = false;
          wallpaperMuteForWindows = true;
        } else {
          wallpaperSuspended = true;
          wallpaperMuteForWindows = false;
        }
        applySuspensionState();
      }

      function applySuspensionState() {
        if (currentFallback.item) {
          if ("suspended" in currentFallback.item) {
            currentFallback.item.suspended = wallpaperSuspended;
          }
          if ("muteForWindows" in currentFallback.item) {
            currentFallback.item.muteForWindows = wallpaperMuteForWindows;
          }
        }
        if (nextFallback.item) {
          if ("suspended" in nextFallback.item) {
            nextFallback.item.suspended = wallpaperSuspended;
          }
          if ("muteForWindows" in nextFallback.item) {
            nextFallback.item.muteForWindows = wallpaperMuteForWindows;
          }
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
        currentWallpaperPath = wallpaperPath;
        currentWallpaperType = WallpaperService.getWallpaperType(wallpaperPath);
        nextWallpaperType = currentWallpaperType;
        useFallbackTransition = (currentWallpaperType === "video");
        updateWallpaperSuspension();
        performStartupTransition();
      }

      // ------------------------------------------------------
      function setWallpaperImmediate(source) {
        transitionAnimation.stop();
        fallbackTransitionAnimation.stop();
        transitionProgress = 0.0;
        fallbackTransitionProgress = 0.0;

        currentWallpaperPath = futureWallpaper;
        currentWallpaperType = WallpaperService.getWallpaperType(currentWallpaperPath);
        nextWallpaperType = currentWallpaperType;
        useFallbackTransition = (currentWallpaperType === "video");
        updateWallpaperSuspension();

        if (useFallbackTransition) {
          currentFallback.sourceComponent = getFallbackComponent(currentWallpaperType);
          if (currentFallback.item && currentFallback.item.setSource) {
            currentFallback.item.setSource(source);
            currentFallback.item.opacity = 1;
            if (currentFallback.item.visualOpacity !== undefined) {
              currentFallback.item.visualOpacity = 1;
            }
          }
          if (nextFallback.item) {
            nextFallback.item.opacity = 0;
          }
          if (nextFallback.active) {
            nextFallback.active = false;
          }
          applySuspensionState();
        } else {
          // Clear nextWallpaper completely to free texture memory
          nextWallpaper.source = "";
          nextWallpaper.sourceSize = undefined;

          currentWallpaper.source = "";

          Qt.callLater(() => {
                         currentWallpaper.source = source;
                       });
        }
        updateWallpaperSuspension();
      }

      // ------------------------------------------------------
      function setWallpaperWithTransition(source) {
        if (useFallbackTransition) {
          startFallbackTransition(source);
          return;
        }

        if (source === currentWallpaper.source) {
          return;
        }

        if (transitioning) {
          // We are interrupting a transition - handle cleanup properly
          transitionAnimation.stop();
          transitionProgress = 0;

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
          return;
        }

        nextWallpaper.source = source;
        currentWallpaper.asynchronous = false;
        transitionAnimation.start();
      }

      function startFallbackTransition(source) {
        transitionAnimation.stop();
        fallbackTransitionAnimation.stop();
        fallbackTransitionProgress = 0.0;

        currentFallback.sourceComponent = getFallbackComponent(currentWallpaperType);
        if (currentFallback.item && currentWallpaperPath) {
          currentFallback.item.setSource(getDisplaySource(currentWallpaperPath));
          currentFallback.item.opacity = 1;
          if (currentFallback.item.visualOpacity !== undefined) {
            currentFallback.item.visualOpacity = 1;
          }
        }

        nextFallback.sourceComponent = getFallbackComponent(nextWallpaperType);
        nextFallback.active = true;

        Qt.callLater(() => {
                       if (nextFallback.item && nextFallback.item.setSource) {
                         nextFallback.item.setSource(source);
                         applySuspensionState();
                         fallbackTransitionAnimation.start();
                       }
                     });
      }

      function finalizeFallbackTransition() {
        fallbackTransitionProgress = 0.0;
        currentWallpaperPath = futureWallpaper;
        currentWallpaperType = nextWallpaperType;
        nextWallpaperType = currentWallpaperType;
        useFallbackTransition = (currentWallpaperType === "video");

        currentFallback.sourceComponent = getFallbackComponent(currentWallpaperType);
        if (currentFallback.item) {
          var newSource = nextFallback.item && nextFallback.item.source ? nextFallback.item.source : getDisplaySource(currentWallpaperPath);
          if (currentFallback.item.setSource) {
            currentFallback.item.setSource(newSource);
          }
          currentFallback.item.opacity = 1;
          if (currentFallback.item.visualOpacity !== undefined) {
            currentFallback.item.visualOpacity = 1;
          }
        }

        nextFallback.active = false;
        currentWallpaper.source = getDisplaySource(currentWallpaperPath);
        currentWallpaper.sourceSize = undefined;
        recalculateImageSizes();
        applySuspensionState();
      }

      // ------------------------------------------------------
      // Main method that actually trigger the wallpaper change
      function changeWallpaper() {
        // Get the transitionType from the settings
        transitionType = Settings.data.wallpaper.transitionType;

        if (transitionType == "random") {
          var index = Math.floor(Math.random() * allTransitions.length);
          transitionType = allTransitions[index];
        }

        // Ensure the transition type really exists
        if (transitionType !== "none" && !allTransitions.includes(transitionType)) {
          transitionType = "fade";
        }

        nextWallpaperType = WallpaperService.getWallpaperType(futureWallpaper);
        useFallbackTransition = (currentWallpaperType === "video" || nextWallpaperType === "video");
        var displaySource = getDisplaySource(futureWallpaper);

        if (WallpaperService.isVideoFile(futureWallpaper)) {
          WallpaperService.generateWallpaperPreview(futureWallpaper);
        }
        updateWallpaperSuspension();

        switch (transitionType) {
        case "none":
          setWallpaperImmediate(displaySource);
          break;
        case "wipe":
          wipeDirection = Math.random() * 4;
          setWallpaperWithTransition(displaySource);
          break;
        case "disc":
          discCenterX = Math.random();
          discCenterY = Math.random();
          setWallpaperWithTransition(displaySource);
          break;
        case "stripes":
          stripesCount = Math.round(Math.random() * 20 + 4);
          stripesAngle = Math.random() * 360;
          setWallpaperWithTransition(displaySource);
          break;
        default:
          setWallpaperWithTransition(displaySource);
          break;
        }
      }

      // ------------------------------------------------------
      // Dedicated function for startup animation
      function performStartupTransition() {
        // Get the transitionType from the settings
        transitionType = Settings.data.wallpaper.transitionType;

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

        nextWallpaperType = WallpaperService.getWallpaperType(futureWallpaper);
        useFallbackTransition = (currentWallpaperType === "video" || nextWallpaperType === "video");
        var displaySource = getDisplaySource(futureWallpaper);

        if (WallpaperService.isVideoFile(futureWallpaper)) {
          WallpaperService.generateWallpaperPreview(futureWallpaper);
        }

        switch (transitionType) {
        case "none":
          setWallpaperImmediate(displaySource);
          break;
        case "wipe":
          wipeDirection = Math.random() * 4;
          setWallpaperWithTransition(displaySource);
          break;
        case "disc":
          // Force center origin for elegant startup animation
          discCenterX = 0.5;
          discCenterY = 0.5;
          setWallpaperWithTransition(displaySource);
          break;
        case "stripes":
          stripesCount = Math.round(Math.random() * 20 + 4);
          stripesAngle = Math.random() * 360;
          setWallpaperWithTransition(displaySource);
          break;
        default:
          setWallpaperWithTransition(displaySource);
          break;
        }
        // Mark startup transition complete
        isStartupTransition = false;
      }
    }
  }
}
