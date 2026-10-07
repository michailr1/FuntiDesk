on run {daemon_file, agent_file, user}

  set sh1 to "echo " & quoted form of daemon_file & " > /Library/LaunchDaemons/cc.funti.funtidesk.service.plist && chown root:wheel /Library/LaunchDaemons/cc.funti.funtidesk.service.plist;"

  set sh2 to "echo " & quoted form of agent_file & " > /Library/LaunchAgents/cc.funti.funtidesk.server.plist && chown root:wheel /Library/LaunchAgents/cc.funti.funtidesk.server.plist;"

  set sh3 to "cp -rf /Users/" & user & "/Library/Preferences/com.carriez.FuntiDesk/FuntiDesk.toml /var/root/Library/Preferences/com.carriez.RustDesk/;"

  set sh4 to "cp -rf /Users/" & user & "/Library/Preferences/com.carriez.FuntiDesk/FuntiDesk2.toml /var/root/Library/Preferences/com.carriez.RustDesk/;"

  set sh5 to "launchctl load -w /Library/LaunchDaemons/cc.funti.funtidesk.service.plist;"

  set sh to sh1 & sh2 & sh3 & sh4 & sh5

  do shell script sh with prompt "FuntiDesk wants to install daemon and agent" with administrator privileges
end run
