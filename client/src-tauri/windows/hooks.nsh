; Airhand 安装包的附加步骤：Tauri NSIS 模板的钩子（tauri.conf.json → bundle.windows.nsis.installerHooks）。
;
; 两种安装方式（tauri.conf.json 的 installMode 是 both，用 NSIS 的 MultiUser.nsh，结果在 $MultiUser.InstallMode）：
; * 为所有用户安装（AllUsers）：需要管理员权限，只能装在 Program Files 里（.onVerifyInstDir）。被控端作为系统服务运行，
;   锁屏、登录界面和 UAC 确认框也能控制（src/winsvc/mod.rs）；
; * 仅为我安装（CurrentUser）：不需要管理员权限，默认装到 %LOCALAPPDATA%\Programs，不能装在 Program Files、Windows 里。
;   没有系统服务，被控端在托盘进程里运行（src/winsvc/user.rs）。
;
; 选择安装方式（AirhandChooseMode）：
; * 已经装过：按原来的方式升级，不再询问（要换安装方式先卸载）。为所有用户装过、这次却没有管理员权限时，
;   说明一下，以管理员身份重新运行安装程序（普通账户要输入管理员密码）；
; * 没装过：管理员账户（MultiUser 让安装程序一启动就提升了权限）在安装方式页面上选，默认为所有用户安装；
;   普通账户看不到那个页面（MultiUser 直接按仅为我安装），先问一句：要为所有用户安装就以管理员身份重新运行。
; 卸载程序按自己所在的位置找出属于哪一份安装（un.AirhandBindUninstall），不信 MultiUser 按注册表猜的
; （普通账户卸载为所有用户安装的那份时它会猜成仅为我安装）；为所有用户安装的那份需要管理员权限，没有就以管理员身份重新运行。
;
; airhand.exe 的命令行（src/winsvc/mod.rs）：
; * 安装：复制完文件后运行 `--install`（注册并启动系统服务，按 config.toml 设置开机自动启动）或 `--install-user`
;   （记下安装位置，按 config.toml 设置登录时自动启动）；config.toml 不存在时新建；
; * 升级：复制文件之前运行旧版本的 `--stop`：停下这一份 Airhand（它的服务、托盘），否则 airhand.exe 正在使用，无法覆盖。
;   升级前本会话里开着托盘的话（它等着的命名事件 Local\Airhand.Quit 在），装好后以登录的用户的身份重新打开：
;   远程帮别人升级时，连接随之恢复；
; * 卸载：运行 `--uninstall`：删除这一份注册的服务、启动项、安装位置记录，让它的托盘退出。
; 卸载（不是升级）时还删除安装目录里程序运行时生成的文件（config.toml）、安装程序和 Tauri 记下的注册表项和应用数据目录
; （不管有没有勾选"删除应用程序数据"）、防火墙里为 airhand.exe 添加的规则、任务管理器"启动应用"里对它的启用 / 禁用记录
; （删掉 Run 项时系统不删它，留着的话重新安装后 Run 项还被"已禁用"挡着，见 src/winsvc/mod.rs 的 STARTUP_APPROVED_KEY）。
; 第一次安装（不是升级）时也删一次这条记录：以前的版本卸载时没删。升级时保留，那是用户在任务管理器里的选择。
;
; 升级时如果选择"先卸载旧版本"，旧版本的卸载程序由新的安装程序启动：安装程序启动时设置环境变量 AIRHAND_UPGRADE，
; 卸载程序继承了它，就保留 config.toml（控制码、服务器设置、控制台的"我的设备"）。直接卸载时没有这个变量，配置文件一起删除。
; 重新运行同一个版本的安装程序、在里面选"卸载 Airhand"是真的卸载：安装程序还把自己的版本放进 AIRHAND_INSTALLER_VERSION，
; 卸载程序看到和自己的版本一样，就照样全部删除。被动安装（/P）遇到同一个版本时会自动先卸载再装，那是重装，不传版本、保留配置。
; 这两个变量只给旧版本的卸载程序用（"已安装旧版本"页面上，复制文件之前），开始复制文件时（PREINSTALL）就清掉：
; 没有提升权限时 RunAsUser 直接 ShellExecute，之后由安装程序打开的 Airhand 会继承它们，它再启动卸载程序的话
; （仅为我安装的那份给为所有用户安装的那份让开时，见 src/winsvc/user.rs 的 step_aside），卸载就被当成了升级。
; airhand.exe 启动时也会去掉它们（src/winsvc/mod.rs 的 forget_installer_env）。
; 删除配置文件时服务已经停了（PREUNINSTALL），服务里"配置文件被删掉就重新生成"的检查不会再把它写回来。
;
; 虚拟显示器驱动（MttVDD，随包带在安装目录的 vdd\ 里，见 windows/vdd/README.md 和 src/host/virtual_display/）：
; 显示器关了电源也能远程控制、防窥模式都靠它。只在为所有用户安装时有用（被控端是 SYSTEM，才能启用、停用它）：
; * 安装：Airhand 装过它（注册表里有记录）就升级；没装过、也没问过就问一次（不管答什么都记下问过了，升级时不再问）。
;   静默、被动安装不问、不装。装的时候 Windows 可能弹出"要安装这个设备软件吗"（驱动不是微软签名的），
;   所以用 ExecWait 在前台运行 `--install-vdd`（nsExec 会把窗口藏起来），在启动服务之前；
; * 卸载：确认页之前多一页（un.AirhandVddPage），勾选"同时删除虚拟显示器驱动"（默认不勾）。
;   Airhand 装的才问；静默、被动卸载和升级（AIRHAND_UPGRADE）时不问、留着。不管删不删，`--uninstall` 都先把它停用、
;   防窥撤下的显示器放回去。模板自己的确认页上加不了勾选框（它的 un.ConfirmShow 画了"删除应用程序数据"），
;   这个文件又在模板声明页面之前引入，所以这一页排在确认页前面。
;
; 这个文件在模板的大部分定义之前引入：模板的 ${UNINSTKEY} 这些还没定义、语言还没加载，$MultiUser.InstallMode 也还没声明。
; 所以这里的函数用不了它们（插在安装、卸载步骤里的 NSIS_HOOK_* 宏展开得晚，可以用），LangString 直接用语言 ID
; （2052 简体中文、1033 英语，和 tauri.conf.json 的 languages 对应）。

; 和模板的 UNINSTKEY 一样（${PRODUCTNAME} 是 Airhand）
!define AIRHAND_UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Airhand"
!define AIRHAND_RUNKEY "Software\Microsoft\Windows\CurrentVersion\Run"
; 和 src/winsvc/user.rs 一样：仅为当前用户安装时记下安装位置的地方。不分大小写的话它也是模板的 ${MANUKEY}，只删自己的值
!define AIRHAND_USERKEY "Software\Airhand"
; 和 src/winsvc/mod.rs 的 STARTUP_APPROVED_KEY 一样：任务管理器"启动应用"里对 Run 项的启用 / 禁用记录，值名和 Run 里的一样。
; HKLM 的 Run 项记在 HKLM 下，HKCU 的记在 HKCU 下，所以和 Run 项一样按 SHCTX 删
!define AIRHAND_STARTUPKEY "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
; 和 src/host/virtual_display/device.rs 的 RECORD 一样：Airhand 装的虚拟显示器驱动（Instance）、问过用户了（Asked，只有安装包用）
!define AIRHAND_VDDKEY "Software\Airhand\VirtualDisplay"

!include nsDialogs.nsh

; 1：有管理员权限（安装 / 卸载程序已经提升了权限）
Var AirhandAdmin
; 已经装过的那一份（卸载时：卸载程序所属的那一份）：AllUsers / CurrentUser / 空
Var AirhandExisting
; 1：升级前本会话里开着托盘，装好后重新打开
Var AirhandRelaunch

; 安装方式页面（MultiUser.nsh）上的说明：写清楚两种方式的区别
LangString AirhandModeTop 2052 "为所有用户安装：Airhand 作为系统服务运行，锁屏、登录界面和 UAC 确认框也能被远程控制，开机后不用登录就能连上。$\r$\n$\r$\n仅为我安装：不需要管理员权限，但上面这些都不行，以管理员身份运行的窗口也只能看、不能操作。"
LangString AirhandModeTop 1033 "For all users: Airhand runs as a system service, so the lock screen, the sign-in screen and UAC prompts can be controlled too, even before anyone signs in.$\r$\n$\r$\nJust for me: no administrator rights needed, but none of the above, and windows running as administrator can only be viewed."
LangString AirhandModeAllUsers 2052 "为所有用户安装（推荐）"
LangString AirhandModeAllUsers 1033 "Install for all users (recommended)"
LangString AirhandModeCurrentUser 2052 "仅为我安装"
LangString AirhandModeCurrentUser 1033 "Install just for me"
!define MULTIUSER_INSTALLMODEPAGE_TEXT_TOP "$(AirhandModeTop)"
!define MULTIUSER_INSTALLMODEPAGE_TEXT_ALLUSERS "$(AirhandModeAllUsers)"
!define MULTIUSER_INSTALLMODEPAGE_TEXT_CURRENTUSER "$(AirhandModeCurrentUser)"
!define MULTIUSER_PAGE_CUSTOMFUNCTION_PRE AirhandModePagePre

; 普通账户、没装过：问要不要为所有用户安装
LangString AirhandAskAllUsers 2052 "要为所有用户安装 Airhand 吗？$\r$\n$\r$\n为所有用户安装（推荐）：Airhand 作为系统服务运行，锁屏、登录界面和 UAC 确认框也能被远程控制。需要输入管理员密码。$\r$\n$\r$\n仅为你安装：不需要管理员权限，但上面这些都不行，以管理员身份运行的窗口也只能看、不能操作。$\r$\n$\r$\n选“是”为所有用户安装，选“否”仅为你安装。"
LangString AirhandAskAllUsers 1033 "Install Airhand for all users?$\r$\n$\r$\nFor all users (recommended): Airhand runs as a system service, so the lock screen, the sign-in screen and UAC prompts can be controlled too. Needs an administrator password.$\r$\n$\r$\nJust for you: no administrator rights needed, but none of the above, and windows running as administrator can only be viewed.$\r$\n$\r$\nChoose Yes to install for all users, No to install just for you."
; 普通账户、为所有用户装过
LangString AirhandUpgradeNeedsAdmin 2052 "这台电脑已经为所有用户安装了 Airhand，升级或重新安装需要管理员权限。$\r$\n$\r$\n点“确定”后按提示输入管理员密码。"
LangString AirhandUpgradeNeedsAdmin 1033 "Airhand is installed for all users on this computer, so upgrading or reinstalling it needs administrator rights.$\r$\n$\r$\nClick OK, then enter an administrator password when asked."
LangString AirhandNoAdmin 2052 "没有获得管理员权限，安装程序将退出。"
LangString AirhandNoAdmin 1033 "Didn't get administrator rights, Setup will exit."
LangString AirhandUninstallNeedsAdmin 2052 "卸载为所有用户安装的 Airhand 需要管理员权限。"
LangString AirhandUninstallNeedsAdmin 1033 "Uninstalling Airhand installed for all users needs administrator rights."
LangString AirhandUserFailed 2052 "无法完成 Airhand 的安装（$0），Airhand 不能运行。"
LangString AirhandUserFailed 1033 "Can't finish installing Airhand ($0), it won't run."
LangString AirhandServiceFailed 2052 "无法安装 Airhand 系统服务（$0），本机将不能被远程控制。"
LangString AirhandServiceFailed 1033 "Can't install the Airhand system service ($0), this computer can't be controlled remotely."

; 虚拟显示器驱动（见文件开头）
LangString AirhandAskVdd 2052 "要安装虚拟显示器驱动吗？$\r$\n$\r$\n装上之后：$\r$\n• 这台电脑的显示器关了电源（或者没接显示器）也能被远程控制；$\r$\n• 控制端可以打开防窥模式：这台电脑的显示器全部黑屏、键盘鼠标不起作用，只有控制端看得到、操作得了。$\r$\n$\r$\n驱动来自开源项目 Virtual Display Driver（MIT 许可），平时停用着，不显示任何东西。Windows 可能会问是否安装发布者为$\"SignPath Foundation$\"的设备软件，请选择安装。$\r$\n$\r$\n以后也可以以管理员身份运行 airhand.exe --install-vdd 安装；卸载 Airhand 时可以选择一起删除。"
LangString AirhandAskVdd 1033 "Install the virtual display driver?$\r$\n$\r$\nWith it:$\r$\n• this computer can be controlled remotely even when its monitor is switched off (or there's no monitor);$\r$\n• controllers can turn on privacy mode: this computer's monitors go blank and its keyboard and mouse stop working, so only the controller can see and control it.$\r$\n$\r$\nThe driver comes from the open-source Virtual Display Driver project (MIT license) and stays disabled, showing nothing, until it's needed. Windows may ask whether to install device software from $\"SignPath Foundation$\": choose Install.$\r$\n$\r$\nYou can also install it later by running airhand.exe --install-vdd as administrator, and remove it when uninstalling Airhand."
LangString AirhandVddFailed 2052 "没能安装虚拟显示器驱动：显示器关了电源时不能远程控制，也不能使用防窥模式。$\r$\n$\r$\n以后可以以管理员身份运行 airhand.exe --install-vdd 重试。"
LangString AirhandVddFailed 1033 "Couldn't install the virtual display driver: this computer can't be controlled while its monitor is off, and privacy mode isn't available.$\r$\n$\r$\nYou can retry later by running airhand.exe --install-vdd as administrator."
LangString AirhandVddForeign 2052 "这台电脑已经装有别的程序（例如 Sunshine）在用的 Virtual Display Driver。Airhand 不改动它，所以不能使用防窥模式，显示器关了电源时也不能远程控制。"
LangString AirhandVddForeign 1033 "Another program (Sunshine, for example) already uses a Virtual Display Driver on this computer. Airhand leaves it alone, so privacy mode isn't available and this computer can't be controlled while its monitor is off."
LangString AirhandVddPageTitle 2052 "虚拟显示器驱动"
LangString AirhandVddPageTitle 1033 "Virtual display driver"
LangString AirhandVddPageSubtitle 2052 "选择是否一起删除"
LangString AirhandVddPageSubtitle 1033 "Choose whether to remove it too"
LangString AirhandVddPageText 2052 "安装 Airhand 时装了虚拟显示器驱动（Virtual Display Driver），显示器关了电源时的远程控制和防窥模式用的就是它。$\r$\n$\r$\n它平时停用着，不显示任何东西。留着的话，以后重新安装 Airhand 时不用再装；也可以之后在设备管理器的$\"显示适配器$\"里卸载它。"
LangString AirhandVddPageText 1033 "The virtual display driver (Virtual Display Driver) was installed with Airhand: remote control while the monitor is off and privacy mode use it.$\r$\n$\r$\nIt stays disabled and shows nothing. If you keep it, reinstalling Airhand later won't need to install it again; you can also uninstall it later under $\"Display adapters$\" in Device Manager."
LangString AirhandVddRemove 2052 "同时删除虚拟显示器驱动"
LangString AirhandVddRemove 1033 "Also remove the virtual display driver"

; 选择安装目录的页面：说明两种方式各能装在哪里（不符合时"下一步"不能点，见 .onVerifyInstDir）
LangString AirhandDirTop 2052 "为所有用户安装时只能装在 Program Files 里：Airhand 作为系统服务运行，别的位置普通用户可能改得了它的程序。仅为我安装时不能装在 Program Files 或 Windows 文件夹里：设置要保存在程序旁边。"
LangString AirhandDirTop 1033 "For all users, Airhand must be in Program Files: it runs as a system service, and elsewhere ordinary users might be able to change it. Just for you, it can't be in Program Files or the Windows folder: its settings are saved next to it."
!define MUI_DIRECTORYPAGE_TEXT_TOP "$(AirhandDirTop)"

; ───────────────────────────── 安装程序 ─────────────────────────────

; 安装程序的界面初始化时（在安装方式页面、"已安装旧版本"页面之前）调用
!define MUI_CUSTOMFUNCTION_GUIINIT AirhandGuiInit
Function AirhandGuiInit
  System::Call 'kernel32::SetEnvironmentVariableW(w "AIRHAND_UPGRADE", w "1")'
  Push $0
  ClearErrors
  ${GetOptions} $CMDLINE "/P" $0
  ${If} ${Errors}
    Call AirhandShareVersion
    Call AirhandChooseMode
  ${Else}
    ; 被动安装（/P）：不问用户，需要管理员权限而没有时失败
    Call AirhandBindInstall
    ${If} $AirhandExisting == "AllUsers"
    ${AndIf} $AirhandAdmin != 1
      SetErrorLevel 740 ; ERROR_ELEVATION_REQUIRED
      Quit
    ${EndIf}
  ${EndIf}
  Call AirhandCheckRunning
  Pop $0
FunctionEnd

; 有没有管理员权限（和 MultiUser.nsh 的判断一样）
!macro AIRHAND_CHECK_ADMIN UN
Function ${UN}AirhandCheckAdmin
  Push $0
  UserInfo::GetAccountType
  Pop $0
  StrCpy $AirhandAdmin 0
  ${If} $0 == "Admin"
  ${OrIf} $0 == "Power"
    StrCpy $AirhandAdmin 1
  ${EndIf}
  Pop $0
FunctionEnd
!macroend
!insertmacro AIRHAND_CHECK_ADMIN ""
!insertmacro AIRHAND_CHECK_ADMIN "un."

; 找已经装过的那一份，按它的方式安装（升级）。为所有用户装过而没有管理员权限时不切换，由调用的地方处理
Function AirhandBindInstall
  Push $0
  Call AirhandCheckAdmin
  StrCpy $AirhandExisting ""
  ReadRegStr $0 HKLM "${AIRHAND_UNINSTKEY}" "UninstallString"
  ${If} $0 != ""
    StrCpy $AirhandExisting "AllUsers"
    ${If} $AirhandAdmin == 1
      Call MultiUser.InstallMode.AllUsers
    ${EndIf}
  ${Else}
    ReadRegStr $0 HKCU "${AIRHAND_UNINSTKEY}" "UninstallString"
    ${If} $0 != ""
      StrCpy $AirhandExisting "CurrentUser"
      Call MultiUser.InstallMode.CurrentUser
    ${EndIf}
  ${EndIf}
  Pop $0
FunctionEnd

; 交互安装时选择安装方式（见文件开头）
Function AirhandChooseMode
  Call AirhandBindInstall
  ${If} $AirhandExisting == "AllUsers"
    ${If} $AirhandAdmin != 1
      MessageBox MB_OKCANCEL|MB_ICONINFORMATION "$(AirhandUpgradeNeedsAdmin)" IDOK airhand_upgrade_elevate
      Quit
      airhand_upgrade_elevate:
      Call AirhandRelaunchElevated
    ${EndIf}
  ${ElseIf} $AirhandExisting == ""
  ${AndIf} $AirhandAdmin != 1
    MessageBox MB_YESNOCANCEL|MB_ICONQUESTION "$(AirhandAskAllUsers)" IDYES airhand_all_users IDNO airhand_just_me
    Quit
    airhand_all_users:
    Call AirhandRelaunchElevated
    airhand_just_me:
  ${EndIf}
FunctionEnd

; 以管理员身份重新运行安装程序（普通账户要输入管理员密码），为所有用户安装；这个安装程序随即退出
Function AirhandRelaunchElevated
  ${GetParameters} $0
  ClearErrors
  ExecShell "runas" "$EXEPATH" "$0 /AllUsers"
  ${If} ${Errors}
    MessageBox MB_ICONEXCLAMATION "$(AirhandNoAdmin)"
  ${EndIf}
  Quit
FunctionEnd

; 安装方式页面：已经装过（按原来的方式升级），或者命令行里指定了方式（例如以管理员身份重新运行时）就不再询问
Function AirhandModePagePre
  ${If} $AirhandExisting != ""
    Abort
  ${EndIf}
  Push $0
  ClearErrors
  ${GetOptions} $CMDLINE "/AllUsers" $0
  ${IfNot} ${Errors}
    Pop $0
    Abort
  ${EndIf}
  ClearErrors
  ${GetOptions} $CMDLINE "/CurrentUser" $0
  ${IfNot} ${Errors}
    Pop $0
    Abort
  ${EndIf}
  Pop $0
FunctionEnd

; $INSTDIR 在 DIR 里面（不是 DIR 本身）的话 RESULT 为 1，否则为 0（不分大小写）
!macro AIRHAND_UNDER RESULT DIR
  Push $R0
  Push $R1
  StrLen $R0 "${DIR}\"
  StrCpy $R1 $INSTDIR $R0
  StrCpy ${RESULT} 0
  ${IfThen} $R1 == "${DIR}\" ${|} StrCpy ${RESULT} 1 ${|}
  Pop $R1
  Pop $R0
!macroend
; 安装目录合不合适，结果在 $0（1：合适）：
; * 为所有用户安装：只能在 Program Files 里。服务以 SYSTEM 身份运行这里的程序，别的位置（例如 D:\ 下新建的文件夹）
;   普通用户可能改得了它，等于把 SYSTEM 权限送给了他们；
; * 仅为我安装：不能在 Program Files、Windows 里。托盘要在程序旁边写 config.toml，那里没有写权限。
; 这里用不了 $MultiUser.InstallMode（见文件开头）：为所有用户安装时 MultiUser 把 shell 变量切换成所有用户的，
; $APPDATA 就和环境变量 APPDATA 不一样了
Function AirhandCheckInstDir
  Push $1
  ReadEnvStr $1 APPDATA
  ${If} $1 != $APPDATA
    StrCpy $0 0
    !insertmacro AIRHAND_UNDER $1 $PROGRAMFILES64
    ${IfThen} $1 == 1 ${|} StrCpy $0 1 ${|}
    !insertmacro AIRHAND_UNDER $1 $PROGRAMFILES32
    ${IfThen} $1 == 1 ${|} StrCpy $0 1 ${|}
  ${Else}
    StrCpy $0 1
    !insertmacro AIRHAND_UNDER $1 $PROGRAMFILES64
    ${IfThen} $1 == 1 ${|} StrCpy $0 0 ${|}
    !insertmacro AIRHAND_UNDER $1 $PROGRAMFILES32
    ${IfThen} $1 == 1 ${|} StrCpy $0 0 ${|}
    !insertmacro AIRHAND_UNDER $1 $WINDIR
    ${IfThen} $1 == 1 ${|} StrCpy $0 0 ${|}
  ${EndIf}
  Pop $1
FunctionEnd


; 选择安装目录的页面上每改一次目录就检查一次，不合适时"下一步"不能点
Function .onVerifyInstDir
  Push $0
  Call AirhandCheckInstDir
  ${If} $0 != 1
    Pop $0
    Abort
  ${EndIf}
  Pop $0
FunctionEnd

; 本会话里有没有开着的托盘：它等着命名事件 Local\Airhand.Quit（见 src/winsvc/mod.rs 的 watch_quit）。
; 按已有的安装选好了方式之后再看：一台电脑上只有一份 Airhand 在运行，开着的就是要升级的这一份
Function AirhandCheckRunning
  Push $0
  System::Call 'kernel32::OpenEventW(i 0x00100000, i 0, w "Local\Airhand.Quit") p .r0'
  ${If} $0 P<> 0
    StrCpy $AirhandRelaunch 1
    System::Call 'kernel32::CloseHandle(p r0)'
  ${EndIf}
  Pop $0
FunctionEnd

; 把本安装程序的版本放进环境变量 AIRHAND_INSTALLER_VERSION。版本取自安装程序版本信息里的 ProductVersion
; （Tauri 模板里写的就是 ${VERSION}）：这个文件比模板里的 !define VERSION 更早被引入，这里用不了 ${VERSION}，只能运行时读。
; 读不到时不设置，卸载程序就按升级处理（保留配置），和以前一样
Function AirhandShareVersion
  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  StrCpy $4 ""
  System::Call 'version::GetFileVersionInfoSizeW(w "$EXEPATH", p 0) i .r0'
  ${If} $0 > 0
    System::Alloc $0
    Pop $1
    System::Call 'version::GetFileVersionInfoW(w "$EXEPATH", i 0, i r0, p r1) i .r2'
    ${If} $2 <> 0
      ; 版本信息里的语言和代码页（NSIS 只写一组）
      System::Call 'version::VerQueryValueW(p r1, w "\VarFileInfo\Translation", *p .r2, *i .r3) i .r0'
      ${If} $0 <> 0
      ${AndIf} $3 >= 4
        System::Call '*$2(&i2 .r0, &i2 .r3)'
        IntFmt $0 "%04x" $0
        IntFmt $3 "%04x" $3
        System::Call 'version::VerQueryValueW(p r1, w "\StringFileInfo\$0$3\ProductVersion", *p .r2, *i .r3) i .r0'
        ${If} $0 <> 0
        ${AndIf} $3 > 0
          System::Call '*$2(&w$3 .r4)'
        ${EndIf}
      ${EndIf}
    ${EndIf}
    System::Free $1
  ${EndIf}
  ${If} $4 != ""
    System::Call 'kernel32::SetEnvironmentVariableW(w "AIRHAND_INSTALLER_VERSION", w r4)'
  ${EndIf}
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

; 静默安装在复制文件之前失败：模板已经用 SetOutPath 建好了安装目录，空着的话删掉，然后退出
Function AirhandQuitBeforeInstall
  SetOutPath $TEMP
  RMDir $INSTDIR
  Quit
FunctionEnd
!macro NSIS_HOOK_PREINSTALL
  ; 旧版本的卸载程序已经运行完了：清掉只给它用的环境变量，之后打开的 Airhand 不再继承（见文件开头）
  System::Call 'kernel32::SetEnvironmentVariableW(w "AIRHAND_UPGRADE", p 0)'
  System::Call 'kernel32::SetEnvironmentVariableW(w "AIRHAND_INSTALLER_VERSION", p 0)'
  ; 静默安装（/S）没有界面初始化：在这里按已有的安装选择方式、检查安装目录。不能问用户，需要管理员权限而没有、
  ; 或者目录不合适（/D= 指定的）时失败
  ${If} ${Silent}
    Call AirhandBindInstall
    ${If} $AirhandExisting == "AllUsers"
    ${AndIf} $AirhandAdmin != 1
      SetErrorLevel 740 ; ERROR_ELEVATION_REQUIRED
      Call AirhandQuitBeforeInstall
    ${EndIf}
    Call AirhandCheckInstDir
    ${If} $0 != 1
      SetErrorLevel 267 ; ERROR_DIRECTORY
      Call AirhandQuitBeforeInstall
    ${EndIf}
    SetOutPath $INSTDIR
    Call AirhandCheckRunning
  ${EndIf}
  ${If} ${FileExists} "$INSTDIR\${MAINBINARYNAME}.exe"
    DetailPrint "Stopping Airhand…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --stop'
    Pop $0
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  ; 第一次安装：删掉以前卸载时留下的任务管理器"已禁用"记录，不然登录时启动的 Run 项还被它挡着（见文件开头）
  ${If} $AirhandExisting == ""
    DeleteRegValue SHCTX "${AIRHAND_STARTUPKEY}" "Airhand"
  ${EndIf}
  ; 虚拟显示器驱动（见文件开头）：启动服务之前装好、停用好
  ${If} $MultiUser.InstallMode == "AllUsers"
    ReadRegStr $0 HKLM "${AIRHAND_VDDKEY}" "Instance"
    ${If} $0 != ""
      DetailPrint "Updating the virtual display driver…"
      ExecWait '"$INSTDIR\${MAINBINARYNAME}.exe" --install-vdd' $0
    ${Else}
      ReadRegDWORD $1 HKLM "${AIRHAND_VDDKEY}" "Asked"
      ${If} $1 <> 1
      ${AndIfNot} ${Silent}
      ${AndIf} $PassiveMode <> 1
        WriteRegDWORD HKLM "${AIRHAND_VDDKEY}" "Asked" 1
        MessageBox MB_YESNO|MB_ICONQUESTION "$(AirhandAskVdd)" IDNO airhand_vdd_done
        DetailPrint "Installing the virtual display driver…"
        ExecWait '"$INSTDIR\${MAINBINARYNAME}.exe" --install-vdd' $0
        ; 2：用户在 Windows 的提示里选了不装，不用再说
        ${If} $0 == 1
          MessageBox MB_ICONEXCLAMATION "$(AirhandVddFailed)"
        ${ElseIf} $0 == 3
          MessageBox MB_ICONINFORMATION "$(AirhandVddForeign)"
        ${EndIf}
        airhand_vdd_done:
      ${EndIf}
    ${EndIf}
  ${EndIf}
  ${If} $MultiUser.InstallMode == "CurrentUser"
    DetailPrint "Setting up Airhand for this user…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --install-user'
    Pop $0
    ${If} $0 != 0
      MessageBox MB_ICONEXCLAMATION "$(AirhandUserFailed)" /SD IDOK
    ${EndIf}
  ${Else}
    DetailPrint "Installing the Airhand service…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --install'
    Pop $0
    ${If} $0 != 0
      MessageBox MB_ICONEXCLAMATION "$(AirhandServiceFailed)" /SD IDOK
    ${EndIf}
  ${EndIf}
  ; 升级前本会话里开着托盘：以登录的用户的身份重新打开（不是提升了权限的安装程序的身份）。
  ; 完成页上勾着"运行 Airhand"的话还会再打开一次，单实例只留一个
  ${If} $AirhandRelaunch = 1
    nsis_tauri_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" ""
  ${EndIf}
!macroend

; ───────────────────────────── 卸载程序 ─────────────────────────────

; 卸载时要不要一起删除虚拟显示器驱动（见文件开头）：1 是要
Var AirhandRemoveVdd
Var AirhandVddCheckbox
UninstPage custom un.AirhandVddPage un.AirhandVddPageLeave

Function un.AirhandVddPage
  StrCpy $AirhandRemoveVdd 0
  ${If} ${Silent}
    Abort
  ${EndIf}
  Push $0
  ; 被动卸载、升级时由安装程序启动的旧版本卸载程序：不问，留着
  ClearErrors
  ${GetOptions} $CMDLINE "/P" $0
  ${IfNot} ${Errors}
    Pop $0
    Abort
  ${EndIf}
  ClearErrors
  ${GetOptions} $CMDLINE "/UPDATE" $0
  ${IfNot} ${Errors}
    Pop $0
    Abort
  ${EndIf}
  ReadEnvStr $0 AIRHAND_UPGRADE
  ${If} $0 == "1"
    Pop $0
    Abort
  ${EndIf}
  ; 不是 Airhand 装的（或者没装）：不关我们的事
  ReadRegStr $0 HKLM "${AIRHAND_VDDKEY}" "Instance"
  ${If} $0 == ""
    Pop $0
    Abort
  ${EndIf}
  Pop $0
  !insertmacro MUI_HEADER_TEXT "$(AirhandVddPageTitle)" "$(AirhandVddPageSubtitle)"
  nsDialogs::Create 1018
  Pop $0
  ${NSD_CreateLabel} 0 0 100% 60u "$(AirhandVddPageText)"
  Pop $0
  ${NSD_CreateCheckbox} 0 68u 100% 12u "$(AirhandVddRemove)"
  Pop $AirhandVddCheckbox
  nsDialogs::Show
FunctionEnd

Function un.AirhandVddPageLeave
  ${NSD_GetState} $AirhandVddCheckbox $AirhandRemoveVdd
FunctionEnd

!define MUI_CUSTOMFUNCTION_UNGUIINIT un.AirhandGuiInit
Function un.AirhandGuiInit
  Call un.AirhandBindUninstall
  ${If} $AirhandExisting == "AllUsers"
  ${AndIf} $AirhandAdmin != 1
    ; 普通账户卸载为所有用户安装的那份（例如从"设置 → 应用"）：以管理员身份重新运行卸载程序，这个随即退出
    ClearErrors
    ExecShell "runas" "$INSTDIR\uninstall.exe"
    ${If} ${Errors}
      MessageBox MB_ICONEXCLAMATION "$(AirhandUninstallNeedsAdmin)"
    ${EndIf}
    Quit
  ${EndIf}
FunctionEnd

; 卸载程序属于哪一份安装：按所在的位置找（卸载信息里的 InstallLocation，带引号），切换到那种方式。
; MultiUser 是按注册表猜的：普通账户卸载为所有用户安装的那份时，它猜成仅为我安装，就会在当前用户的注册表、
; 开始菜单里删东西，真正的服务、文件都还在
Function un.AirhandBindUninstall
  Push $0
  Call un.AirhandCheckAdmin
  StrCpy $AirhandExisting ""
  ReadRegStr $0 HKLM "${AIRHAND_UNINSTKEY}" "InstallLocation"
  ${If} $0 == '"$INSTDIR"'
    StrCpy $AirhandExisting "AllUsers"
    ${If} $AirhandAdmin == 1
      Call un.MultiUser.InstallMode.AllUsers
    ${EndIf}
  ${Else}
    ReadRegStr $0 HKCU "${AIRHAND_UNINSTKEY}" "InstallLocation"
    ${If} $0 == '"$INSTDIR"'
      StrCpy $AirhandExisting "CurrentUser"
      Call un.MultiUser.InstallMode.CurrentUser
    ${EndIf}
  ${EndIf}
  Pop $0
FunctionEnd

!macro NSIS_HOOK_PREUNINSTALL
  ; 静默卸载（/S）没有界面初始化：在这里找出属于哪一份安装。为所有用户安装的那份需要管理员权限，没有就失败
  Call un.AirhandBindUninstall
  ${If} $AirhandExisting == "AllUsers"
  ${AndIf} $AirhandAdmin != 1
    SetErrorLevel 740 ; ERROR_ELEVATION_REQUIRED
    Quit
  ${EndIf}
  DetailPrint "Removing Airhand…"
  nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --uninstall'
  Pop $0
  ${If} $0 != 0
    ; airhand.exe 运行失败（例如已经损坏）：直接删除它注册的东西
    ${If} $MultiUser.InstallMode == "AllUsers"
      nsExec::ExecToLog '"$SYSDIR\sc.exe" stop Airhand'
      Pop $0
      Sleep 3000
      nsExec::ExecToLog '"$SYSDIR\sc.exe" delete Airhand'
      Pop $0
      DeleteRegValue HKLM "${AIRHAND_RUNKEY}" "Airhand"
    ${Else}
      DeleteRegValue HKCU "${AIRHAND_RUNKEY}" "Airhand"
      DeleteRegValue HKCU "${AIRHAND_USERKEY}" "UserInstall"
    ${EndIf}
  ${EndIf}
  ; 勾选了一起删除虚拟显示器驱动（un.AirhandVddPage）：服务已经停了、虚拟显示器停用了，要在删文件之前运行
  ${If} $AirhandRemoveVdd == ${BST_CHECKED}
    DetailPrint "Removing the virtual display driver…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --uninstall-vdd'
    Pop $0
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ReadEnvStr $0 AIRHAND_UPGRADE
  ; 同一个版本的安装程序里选"卸载 Airhand"：不是升级，是真的卸载
  ReadEnvStr $1 AIRHAND_INSTALLER_VERSION
  ${If} $1 == "${VERSION}"
    StrCpy $0 ""
  ${EndIf}
  ${If} $UpdateMode <> 1
  ${AndIf} $0 != "1"
    Delete "$INSTDIR\config.toml"
    Delete "$INSTDIR\config.toml.tmp"
    RMDir "$INSTDIR"
    ; 安装程序记下的安装位置和语言（Tauri 只在勾选"删除应用程序数据"时删除）
    DeleteRegKey SHCTX "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty SHCTX "${MANUKEY}"
    DeleteRegValue HKCU "${MANUPRODUCTKEY}" "Installer Language"
    DeleteRegKey /ifempty HKCU "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty HKCU "${MANUKEY}"
    ; 仅为我安装时记下的安装位置：PREUNINSTALL 的 --uninstall 已经删了值，键空了的话这里删掉（不依赖它和 MANUKEY 同名）
    DeleteRegKey /ifempty HKCU "${AIRHAND_USERKEY}"
    ; 任务管理器"启动应用"里对 Run 项的启用 / 禁用记录（见文件开头）：为所有用户安装时在 HKLM，仅为我安装时在 HKCU
    DeleteRegValue SHCTX "${AIRHAND_STARTUPKEY}" "Airhand"
    ; 没装虚拟显示器驱动（问过、没要）：问过的记录也删掉，重新安装时再问。装着的话记录留着（重新安装时认得它）；
    ; 删掉了的话 --uninstall-vdd 已经整个删掉了。它在 MANUKEY 下面（上面删 MANUKEY 时还不是空的）：删完再试一次
    ReadRegStr $2 HKLM "${AIRHAND_VDDKEY}" "Instance"
    ${If} $2 == ""
      DeleteRegKey HKLM "${AIRHAND_VDDKEY}"
    ${EndIf}
    DeleteRegKey /ifempty HKLM "${MANUKEY}"
    ; Tauri 的应用数据目录（Tauri 同样只在勾选"删除应用程序数据"时删除；Airhand 不用它们，以防万一）。
    ; 要在上面按 SHCTX 删完之后再切换到当前用户
    SetShellVarContext current
    RMDir /r "$APPDATA\${BUNDLEID}"
    RMDir /r "$LOCALAPPDATA\${BUNDLEID}"
    ; 用户在 Windows 防火墙的提示里允许 airhand.exe 时系统添加的规则（仅为我安装、没有管理员权限的话删不掉）
    nsExec::ExecToLog '"$SYSDIR\netsh.exe" advfirewall firewall delete rule name=all program="$INSTDIR\${MAINBINARYNAME}.exe"'
    Pop $0
  ${EndIf}
  ; 控制台的 WebView 临时目录（正常退出时已经删除，这里清理强制结束时的残留）
  FindFirst $1 $2 "$TEMP\airhand-webview-*"
  ${DoWhile} $2 != ""
    RMDir /r "$TEMP\$2"
    FindNext $1 $2
  ${Loop}
  FindClose $1
!macroend
