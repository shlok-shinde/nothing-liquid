import QtQml
import QtQuick
import QtQuick.Controls
import "components"

// Nothing Liquid login screen (SDDM, Qt 6): the same look as the shell's lock
// screen. Your wallpaper, dimmed; the date in dot-matrix; the time in glass;
// and three glass islands: who and which session, the password, power.
// The glass is the shell's own LiquidGlassEffect and shader, copied in by
// sddm/install.sh.
Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "black"

    // The controls' glass follows the desktop's mode: smoked in dark, milky in
    // light. The clock and date sit on the wallpaper and stay as they are.
    readonly property bool light: config.mode === "light"
    readonly property color fg: light ? "#1b1b1b" : "#f2f2f2"
    readonly property color dim: light ? Qt.rgba(0, 0, 0, 0.55) : Qt.rgba(1, 1, 1, 0.6)
    readonly property string dots: dotFont.status === FontLoader.Ready ? dotFont.name : "monospace"
    readonly property string icons: "Material Symbols Rounded"
    property int userIndex: Math.max(userModel.lastIndex, 0)
    property int sessionIndex: Math.max(sessionModel.lastIndex, 0)
    property bool failed: false

    FontLoader {
        id: dotFont
        source: "fonts/Doto.ttf"
    }
    FontLoader {
        id: clockFont
        source: "fonts/Clock.ttf"
    }

    // Names behind the indexes (SDDM's models only hand them to delegates)
    Instantiator {
        id: users
        model: userModel
        delegate: QtObject {
            required property string name
            required property string realName
        }
    }
    Instantiator {
        id: sessions
        model: sessionModel
        delegate: QtObject {
            required property string name
        }
    }
    readonly property var user: users.count > 0 ? users.objectAt(Math.min(root.userIndex, users.count - 1)) : null
    readonly property var session: sessions.count > 0 ? sessions.objectAt(Math.min(root.sessionIndex, sessions.count - 1)) : null

    function login() {
        if (!root.user)
            return;
        sddm.login(root.user.name, password.text, root.sessionIndex);
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            root.failed = true;
            password.text = "";
            shake.restart();
            password.forceActiveFocus();
        }
    }

    Item {
        id: backdropItem
        anchors.fill: parent
        Image {
            anchors.fill: parent
            source: config.background
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(root.width, root.height)
        }
        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: Number(config.dim || 0.25)
        }
    }

    // ---- Date and time ----------------------------------------------------

    property date now: new Date()
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    Column {
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: root.height * 0.11
        }
        spacing: 2

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: root.dots
            font.pixelSize: Math.round(root.height * 0.024)
            color: Qt.rgba(1, 1, 1, 0.9)
            text: Qt.formatDate(root.now, config.dateFormat || "dddd, MMMM d")
        }
        LiquidGlassEffect {
            anchors.horizontalCenter: parent.horizontalCenter
            width: clock.implicitWidth
            height: clock.implicitHeight
            backdrop: backdropItem
            bezel: 10
            refraction: 16
            bodyLens: 0
            frost: 1.5
            rim: 1.0
            brightness: 1.1
            adaptiveDim: 0.1
            tint: Qt.rgba(1, 1, 1, 0.18)
            dispersion: 0.2
            shadow: 0.45

            Text {
                id: clock
                color: "white"
                font.family: clockFont.status === FontLoader.Ready ? clockFont.name : "sans-serif"
                font.pixelSize: Math.round(root.height * 0.17)
                font.weight: Font.Black
                font.variableAxes: ({ "wght": 820 })
                font.letterSpacing: -2
                text: Qt.formatTime(root.now, config.timeFormat || "hh:mm")
            }
        }
    }

    // ---- The islands --------------------------------------------------------

    component Island: Item {
        id: island
        default property alias content: row.data
        property real padding: 8
        implicitWidth: row.implicitWidth + padding * 2
        implicitHeight: 56

        LiquidGlassEffect {
            anchors.fill: parent
            backdrop: backdropItem
            mapTick: islands.x + islands.y + shakeOffset.x
            brightness: root.light ? 1.03 : 0.8
            adaptiveDim: root.light ? 0 : 0.8
            adaptiveBoost: root.light ? 0.85 : 0
            tint: root.light ? Qt.rgba(0.98, 0.98, 0.99, 0.45) : Qt.rgba(0.04, 0.04, 0.05, 0.25)
            shadow: root.light ? 0.2 : 0.28
            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: "white"
            }
        }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 4
        }
    }

    component IconButton: Item {
        id: button
        property string icon
        property bool filled: false
        signal clicked
        width: 40
        height: 40
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: button.filled ? root.fg : root.light ? Qt.rgba(0, 0, 0, area.containsMouse ? 0.08 : 0) : Qt.rgba(1, 1, 1, area.containsMouse ? 0.14 : 0)
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
        }
        Text {
            anchors.centerIn: parent
            font.family: root.icons
            font.pixelSize: 22
            color: button.filled ? (root.light ? "#f2f2f2" : "#111111") : root.fg
            text: button.icon
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    component IslandText: Text {
        anchors.verticalCenter: parent.verticalCenter
        font.family: root.dots
        font.pixelSize: 15
        color: root.fg
    }

    Row {
        id: islands
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: root.height * 0.08
        }
        spacing: 10
        transform: Translate {
            id: shakeOffset
        }

        Island { // Who, and into which session (click either to switch)
            Item {
                width: 4
                height: 1
            }
            IconButton {
                icon: "account_circle"
                onClicked: root.userIndex = (root.userIndex + 1) % Math.max(userModel.count, 1)
            }
            IslandText {
                text: root.user ? (root.user.realName.length > 0 ? root.user.realName : root.user.name) : ""
            }
            Item {
                width: 10
                height: 1
            }
            IconButton {
                icon: "desktop_windows"
                onClicked: root.sessionIndex = (root.sessionIndex + 1) % Math.max(sessionModel.count, 1)
            }
            IslandText {
                text: root.session ? root.session.name : ""
            }
            Item {
                width: 10
                height: 1
            }
        }

        Island { // Password
            TextField {
                id: password
                anchors.verticalCenter: parent.verticalCenter
                width: 240
                leftPadding: 14
                echoMode: TextInput.Password
                passwordCharacter: "●"
                font.family: root.dots
                font.pixelSize: 15
                color: root.fg
                placeholderText: root.failed ? "Incorrect password" : (keyboard.capsLock ? "Password (Caps Lock is on)" : "Password")
                placeholderTextColor: root.failed ? (root.light ? "#c62828" : "#ff8a8a") : root.dim
                background: null
                focus: true
                onTextEdited: root.failed = false
                onAccepted: root.login()
                Component.onCompleted: forceActiveFocus()
            }
            IconButton {
                icon: "arrow_forward"
                filled: true
                onClicked: root.login()
            }
        }

        Island { // Power
            visible: sddm.canSuspend || sddm.canReboot || sddm.canPowerOff
            IconButton {
                visible: sddm.canSuspend
                icon: "dark_mode"
                onClicked: sddm.suspend()
            }
            IconButton {
                visible: sddm.canReboot
                icon: "restart_alt"
                onClicked: sddm.reboot()
            }
            IconButton {
                visible: sddm.canPowerOff
                icon: "power_settings_new"
                onClicked: sddm.powerOff()
            }
        }
    }

    // ---- Brightness and volume ---------------------------------------------
    // login-keys.py, the root service sddm/install.sh sets up, changes them (no
    // desktop is listening at this screen) and writes the new level to
    // /run/nothing-liquid/login-osd. The keys reach this screen too: read it then.

    property var osd: null // { kind: brightness | volume | microphone, value, muted, seq }
    property int osdSeq: -1

    function readOsd() {
        const request = new XMLHttpRequest();
        request.open("GET", "file:///run/nothing-liquid/login-osd", false);
        let state = null;
        try {
            request.send();
            state = JSON.parse(request.responseText);
        } catch (e) {
            return false;
        }
        if (!state || state.seq === root.osdSeq)
            return false;
        root.osdSeq = state.seq;
        root.osd = state;
        osdIsland.shown = true;
        osdHide.restart();
        return true;
    }
    Timer { // the service may answer a moment after the key
        id: osdRead
        property int tries: 0
        interval: 80
        repeat: true
        onTriggered: {
            if (root.readOsd() || ++tries >= 8)
                stop();
        }
    }
    Timer {
        id: osdHide
        interval: 1600
        onTriggered: osdIsland.shown = false
    }
    Shortcut {
        sequences: ["Volume Up", "Volume Down", "Volume Mute", "Microphone Mute", "Monitor Brightness Up", "Monitor Brightness Down"]
        context: Qt.ApplicationShortcut
        autoRepeat: true
        onActivated: {
            osdRead.tries = 0;
            osdRead.restart();
        }
    }
    Component.onCompleted: {
        // Remember where the counter is, so an old level doesn't pop up at startup
        const request = new XMLHttpRequest();
        request.open("GET", "file:///run/nothing-liquid/login-osd", false);
        try {
            request.send();
            root.osdSeq = JSON.parse(request.responseText).seq;
        } catch (e) {}
    }

    Island {
        id: osdIsland
        property bool shown: false
        readonly property string kind: root.osd?.kind ?? ""
        readonly property bool muted: root.osd?.muted ?? false
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: islands.top
            bottomMargin: 18
        }
        padding: 14
        opacity: shown ? 1 : 0
        visible: opacity > 0
        scale: shown ? 1 : 0.92
        Behavior on opacity {
            NumberAnimation {
                duration: 160
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            font.family: root.icons
            font.pixelSize: 22
            color: root.fg
            text: osdIsland.kind === "brightness" ? "light_mode" : osdIsland.kind === "microphone" ? (osdIsland.muted ? "mic_off" : "mic") : (osdIsland.muted || (root.osd?.value ?? 0) === 0 ? "volume_off" : "volume_up")
        }
        Item {
            width: 8
            height: 1
        }
        Rectangle { // the level
            anchors.verticalCenter: parent.verticalCenter
            width: 170
            height: 6
            radius: 3
            color: root.light ? Qt.rgba(0, 0, 0, 0.15) : Qt.rgba(1, 1, 1, 0.2)
            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, (root.osd?.value ?? 0) / 100))
                height: parent.height
                radius: parent.radius
                color: root.fg
                opacity: osdIsland.muted ? 0.35 : 1
                Behavior on width {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }
        }
        Item {
            width: 10
            height: 1
        }
        IslandText {
            width: 42
            horizontalAlignment: Text.AlignRight
            text: osdIsland.muted ? "off" : `${root.osd?.value ?? 0}%`
        }
    }

    SequentialAnimation { // Wrong password
        id: shake
        loops: 1
        NumberAnimation { target: shakeOffset; property: "x"; to: -14; duration: 50 }
        NumberAnimation { target: shakeOffset; property: "x"; to: 12; duration: 60 }
        NumberAnimation { target: shakeOffset; property: "x"; to: -8; duration: 60 }
        NumberAnimation { target: shakeOffset; property: "x"; to: 4; duration: 60 }
        NumberAnimation { target: shakeOffset; property: "x"; to: 0; duration: 50 }
    }
}
