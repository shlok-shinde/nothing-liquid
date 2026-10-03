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

    readonly property color fg: "#f2f2f2"
    readonly property color dim: Qt.rgba(1, 1, 1, 0.6)
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
            color: button.filled ? "white" : Qt.rgba(1, 1, 1, area.containsMouse ? 0.14 : 0)
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
            color: button.filled ? "#111111" : root.fg
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
                placeholderTextColor: root.failed ? "#ff8a8a" : root.dim
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
