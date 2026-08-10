#!/bin/bash
# Regenerates the TSV fixtures. Kept as a generator so the tabs are unambiguous.
t=$'\t'
cat > basic.procs.tsv <<EOF
1${t}0${t}root${t}Sat Jul 25 10:45:02 2026${t}/sbin/launchd
100${t}1${t}alice${t}Sat Jul 25 10:48:00 2026${t}/Applications/cmux.app/Contents/MacOS/cmux
101${t}100${t}alice${t}Sat Jul 25 10:49:00 2026${t}/usr/bin/login -flp alice /bin/bash --noprofile --norc -c exec -l /bin/zsh
102${t}101${t}alice${t}Sat Jul 25 10:49:01 2026${t}-/bin/zsh
103${t}102${t}alice${t}Sat Jul 25 10:49:02 2026${t}/bin/zsh -lic cd -- '/Users/alice/Code/webapp' 2>/dev/null
104${t}103${t}alice${t}Sat Jul 25 10:49:03 2026${t}/Users/alice/.local/bin/claude --session-id e4cb37ec-72b5-4fe2-85b1-784c6ded7fc9 --settings {}
105${t}104${t}alice${t}Sat Jul 25 11:00:00 2026${t}caffeinate -i -t 300
200${t}1${t}alice${t}Sat Jul 25 10:47:00 2026${t}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
201${t}200${t}alice${t}Sat Jul 25 10:47:10 2026${t}/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer
202${t}200${t}alice${t}Sat Jul 25 10:47:11 2026${t}/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=gpu-process
300${t}1${t}root${t}Sat Jul 25 10:45:10 2026${t}/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon
EOF
cat > basic.energy.tsv <<EOF
100${t}1.0${t}0.5
104${t}20.0${t}18.0
105${t}0.1${t}0.0
200${t}0.5${t}0.2
201${t}6.0${t}4.0
202${t}2.0${t}1.0
300${t}9.0${t}9.0
EOF
: > basic.parents.tsv

# orphan: pid 402's shell (401) died, launchd adopted it. 400 is the app that started it.
cat > orphan.procs.tsv <<EOF
1${t}0${t}root${t}S0${t}/sbin/launchd
400${t}1${t}alice${t}S1${t}/Applications/cmux.app/Contents/MacOS/cmux
402${t}1${t}alice${t}S3${t}node /Users/alice/Code/thing/worker.js
500${t}1${t}alice${t}S5${t}/Applications/Telegram.app/Contents/MacOS/Telegram
EOF
cat > orphan.energy.tsv <<EOF
402${t}12.0${t}11.0
500${t}1.0${t}1.0
EOF
# pid ${t} child-start ${t} remembered-ppid ${t} that parent's start
cat > orphan.parents.tsv <<EOF
402${t}S3${t}400${t}S1
EOF
# same memory, but the remembered parent has since been replaced by a recycled pid
cat > orphan-stale.parents.tsv <<EOF
402${t}S3${t}400${t}SX
EOF

# docker: the Linux VM is a launchd-parented XPC service, not a Docker child
cat > docker.procs.tsv <<EOF
1${t}0${t}root${t}S0${t}/sbin/launchd
100${t}1${t}alice${t}S10${t}/Applications/cmux.app/Contents/MacOS/cmux
101${t}100${t}alice${t}S11${t}/opt/homebrew/bin/codex --session-id 019fab0a-a2ab-79e0-92f0-30fcc3fd5db7
102${t}101${t}alice${t}S12${t}node /Users/alice/Code/thing/api.js
600${t}1${t}alice${t}S1${t}/Applications/Docker.app/Contents/MacOS/com.docker.backend
601${t}1${t}alice${t}S2${t}/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
EOF
cat > docker.energy.tsv <<EOF
600${t}0.5${t}0.5
601${t}14.0${t}13.0
EOF
: > docker.parents.tsv
cat > docker.dbclients.tsv <<EOF
102${t}50db7928634e${t}webapp-db-1${t}Postgres${t}5432${t}1${t}1
EOF

# Raw command outputs for the Docker-port/lsof parser. Two non-Docker clients make
# the relationship ambiguous; Docker's own proxy endpoint must never count.
cat > docker-ports.tsv <<EOF
50db7928634e${t}webapp-db-1${t}postgis:17${t}0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
a98817917f8b${t}webapp-api-1${t}webapp-api${t}0.0.0.0:3000->3000/tcp
EOF
cat > docker-lsof.fields <<EOF
p102
cnode
f18
n[::1]:59828->[::1]:5432
p103
cpython3
f9
n127.0.0.1:59830->127.0.0.1:5432
p600
ccom.docker.backend
f22
n127.0.0.1:59828->127.0.0.1:5432
p700
cChrome
f31
n192.168.1.2:60000->1.2.3.4:443
EOF

# two Chrome instances: the one you launched (700, launchd-parented) and an
# automation-driven one (902) started by a node harness (900) under cmux (800)
CH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
HELP='/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper'
cat > chrome.procs.tsv <<EOF
1${t}0${t}root${t}S0${t}/sbin/launchd
700${t}1${t}alice${t}S1${t}$CH
701${t}700${t}alice${t}S2${t}$HELP --type=renderer
702${t}700${t}alice${t}S3${t}$HELP --type=gpu-process
800${t}1${t}alice${t}S4${t}/Applications/cmux.app/Contents/MacOS/cmux
900${t}800${t}alice${t}S5${t}node /Users/alice/Code/thing/scrape.js
902${t}900${t}alice${t}S6${t}$CH --remote-debugging-port=0 --no-first-run
903${t}902${t}alice${t}S7${t}$HELP --type=renderer
904${t}902${t}alice${t}S8${t}$HELP --type=gpu-process
EOF
cat > chrome.energy.tsv <<EOF
700${t}0.5${t}0.5
701${t}4.0${t}4.0
702${t}2.0${t}2.0
900${t}1.0${t}1.0
902${t}1.5${t}1.5
903${t}30.0${t}30.0
904${t}10.0${t}10.0
EOF
: > chrome.parents.tsv

# agent-browser deliberately daemonises under launchd. Its exact Codex/Claude caller
# is gone, but while cmux is alive the shared automation daemon belongs to cmux rather
# than appearing as an unrelated top-level app. The normal Chrome stays independent.
cat > daemon-browser.procs.tsv <<EOF
1${t}0${t}root${t}S0${t}/sbin/launchd
700${t}1${t}alice${t}S1${t}$CH
701${t}700${t}alice${t}S2${t}$HELP --type=renderer
702${t}700${t}alice${t}S3${t}$HELP --type=gpu-process
800${t}1${t}alice${t}S4${t}/Applications/cmux.app/Contents/MacOS/cmux
850${t}800${t}alice${t}S5${t}/opt/homebrew/bin/codex
900${t}1${t}alice${t}S6${t}/Users/alice/.nvm/bin/agent-browser-darwin-arm64
902${t}900${t}alice${t}S7${t}$CH --remote-debugging-port=0 --user-data-dir=/tmp/agent-browser-chrome-test
903${t}902${t}alice${t}S8${t}$HELP --type=renderer
904${t}902${t}alice${t}S9${t}$HELP --type=gpu-process
EOF
cat > daemon-browser.energy.tsv <<EOF
700${t}0.5${t}0.5
701${t}4.0${t}4.0
702${t}2.0${t}2.0
850${t}0.5${t}0.5
900${t}1.0${t}1.0
902${t}1.5${t}1.5
903${t}30.0${t}30.0
904${t}10.0${t}10.0
EOF
: > daemon-browser.parents.tsv
