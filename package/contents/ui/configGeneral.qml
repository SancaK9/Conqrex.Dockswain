import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property alias cfg_pollInterval: pollSpin.value
    property alias cfg_statsInterval: statsSpin.value
    property alias cfg_showStats: statsBox.checked
    property alias cfg_showCompose: composeBox.checked
    property alias cfg_confirmDestructive: confirmBox.checked
    property alias cfg_sshConnectTimeout: timeoutSpin.value
    property alias cfg_timeFormat24h: time24Box.checked
    property alias cfg_hideExitedDefault: hideExitedBox.checked
    property alias cfg_groupByNetwork: groupNetBox.checked
    property alias cfg_logTail: logTailSpin.value
    property alias cfg_logFollowInterval: logFollowSpin.value
    property alias cfg_nginxDir: nginxDirField.text
    property alias cfg_editor: editorField.text
    property alias cfg_defaultLocalDir: localDirField.text
    property alias cfg_fmPopupWidth: fmWidthSpin.value
    property alias cfg_fmPopupHeight: fmHeightSpin.value
    property alias cfg_confirmDelete: confirmDeleteBox.checked
    property alias cfg_showHiddenFiles: hiddenFilesBox.checked

    property string cfg_dockerCmd: "docker"
    property string cfg_terminal: "konsole"
    property string cfg_sftpTool: "auto"

    Kirigami.FormLayout {

        QQC2.ComboBox {
            id: dockerCombo
            Kirigami.FormData.label: i18n("Docker command:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "docker",      label: i18n("docker") },
                { key: "sudo docker", label: i18n("sudo docker") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_dockerCmd))
            onActivated: page.cfg_dockerCmd = currentValue
        }
        QQC2.ComboBox {
            id: terminalCombo
            Kirigami.FormData.label: i18n("Terminal:")
            editable: true
            model: ["konsole", "alacritty"]
            Component.onCompleted: editText = page.cfg_terminal
            onEditTextChanged: page.cfg_terminal = editText
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: pollSpin
            from: 5; to: 600; stepSize: 5
            Kirigami.FormData.label: i18n("Refresh interval (s):")
        }
        QQC2.CheckBox {
            id: statsBox
            text: i18n("Show CPU / memory stats")
        }
        QQC2.SpinBox {
            id: statsSpin
            from: 15; to: 600; stepSize: 5
            enabled: statsBox.checked
            Kirigami.FormData.label: i18n("Stats interval (s):")
        }
        QQC2.SpinBox {
            id: timeoutSpin
            from: 2; to: 60
            Kirigami.FormData.label: i18n("SSH connect timeout (s):")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: composeBox
            text: i18n("Show compose projects")
        }
        QQC2.CheckBox {
            id: confirmBox
            text: i18n("Confirm destructive actions (remove, compose down)")
        }
        QQC2.CheckBox {
            id: time24Box
            text: i18n("Use 24-hour time")
        }
        QQC2.CheckBox {
            id: hideExitedBox
            text: i18n("Hide exited containers by default")
        }
        QQC2.CheckBox {
            id: groupNetBox
            text: i18n("Group containers by docker network")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: logTailSpin
            from: 50; to: 5000; stepSize: 50
            Kirigami.FormData.label: i18n("Log lines (tail):")
        }
        QQC2.SpinBox {
            id: logFollowSpin
            from: 1; to: 30
            Kirigami.FormData.label: i18n("Log follow interval (s):")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.TextField {
            id: nginxDirField
            Kirigami.FormData.label: i18n("nginx directory:")
            placeholderText: "/etc/nginx"
            Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        }
        QQC2.TextField {
            id: editorField
            Kirigami.FormData.label: i18n("Editor:")
            placeholderText: "kate"
            Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("File manager")
        }

        QQC2.TextField {
            id: localDirField
            Kirigami.FormData.label: i18n("Open local at:")
            placeholderText: i18n("(home)")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        }
        QQC2.ComboBox {
            id: sftpToolCombo
            Kirigami.FormData.label: i18n("Transfer tool:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "auto",  label: i18n("auto (rsync if available, else scp)") },
                { key: "rsync", label: i18n("rsync (live progress + sync)") },
                { key: "scp",   label: i18n("scp (always available)") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_sftpTool))
            onActivated: page.cfg_sftpTool = currentValue
        }
        QQC2.SpinBox {
            id: fmWidthSpin
            from: 24; to: 80
            Kirigami.FormData.label: i18n("Popup width (grid units):")
        }
        QQC2.SpinBox {
            id: fmHeightSpin
            from: 20; to: 60
            Kirigami.FormData.label: i18n("Popup height (grid units):")
        }
        QQC2.CheckBox {
            id: confirmDeleteBox
            text: i18n("Confirm file deletes")
        }
        QQC2.CheckBox {
            id: hiddenFilesBox
            text: i18n("Show hidden files (dotfiles)")
        }
    }
}
