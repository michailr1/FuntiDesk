on run {daemon_file, agent_file, user}

  set sh1 to "echo " & quoted form of daemon_file & " > /Library/LaunchDaemons/cc.funti.funtidesk.service.plist && chown root:wheel /Library/LaunchDaemons/cc.funti.funtidesk.service.plist;"

  set sh2 to "echo " & quoted form of agent_file & " > /Library/LaunchAgents/cc.funti.funtidesk.server.plist && chown root:wheel /Library/LaunchAgents/cc.funti.funtidesk.server.plist;"

  set root_config_dir to "/var/root/Library/Preferences/com.carriez.FuntiDesk"
  set user_config_dir to "/Users/" & user & "/Library/Preferences/com.carriez.FuntiDesk"

  set sh3 to "mkdir -p " & quoted form of root_config_dir & "; test ! -f " & quoted form of (user_config_dir & "/FuntiDesk.toml") & " || cp -f " & quoted form of (user_config_dir & "/FuntiDesk.toml") & " " & quoted form of (root_config_dir & "/FuntiDesk.toml") & ";"

  set sh4 to "test ! -f " & quoted form of (user_config_dir & "/FuntiDesk2.toml") & " || cp -f " & quoted form of (user_config_dir & "/FuntiDesk2.toml") & " " & quoted form of (root_config_dir & "/FuntiDesk2.toml") & ";"

  set sh5 to "launchctl load -w /Library/LaunchDaemons/cc.funti.funtidesk.service.plist;"

  set sh to sh1 & sh2 & sh3 & sh4 & sh5

  do shell script sh with prompt "FuntiDesk wants to install daemon and agent" with administrator privileges
end run
