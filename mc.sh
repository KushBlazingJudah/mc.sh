#!/bin/sh -e

URL_VMF="https://launchermeta.mojang.com/mc/game/version_manifest.json"
URL_ASR="https://resources.download.minecraft.net"

_VERCACHE=""

COLOR_INFO="\033[94;1m"
COLOR_WARN="\033[93;1m"
COLOR_DIE="\033[91;1m"
COLOR_RESET="\033[0m"

# JAVAOPTS="-Xmx1g"

: ${USERNAME:="$(whoami)"}

die() {
	printf '%b>>>%b %s\n' "$COLOR_DIE" "$COLOR_RESET" "$1" >&2
	exit 1
}

warn() {
	printf '%b!!!%b %s\n' "$COLOR_WARN" "$COLOR_RESET" "$1" >&2
}

info() {
	printf '%b>>>%b %s\n' "$COLOR_INFO" "$COLOR_RESET" "$1" >&2
}

ncp() {
	if [ ! -e "$1" ]; then
		die "needed file $1 does not exist; install it with your package manager"
	fi
	cp "$1" "$2"
}

scurl() {
	for i in 1 2 3; do
		curl -\# $* && break
		warn "Retrying (try $i of 3)"
	done
}

list_versions() {
	scurl -fLs "$URL_VMF" | jq -r ".versions[].id" | less
}

fetch_ver() {
	_="$(scurl -fLs "$URL_VMF" | jq -r ".versions[] | select(.id == \"$1\") | .url")"
	scurl -fLs "$_"
}

select_nonnative_urls() {
	printf '%s' "$_VERCACHE" | jq -r '.libraries[] | select(has("natives") | not) | select(
		if has("rules") then
			.rules | all(
				(.action == "allow" and (has("os") | not) or any(.os; .name == "linux"))
				or
				(.action == "disallow" and has("os") and (.os | select(.name != "linux")))
			)
		else
			true
		end
	) | .downloads.artifact.url | select(.)'
}

select_native_urls() {
	printf '%s' "$_VERCACHE" | jq -r '.libraries[] | select(has("natives")) | select(
		if has("rules") then
			.rules | all(
				(.action == "allow" and (has("os") | not) or any(.os; .name == "linux"))
				or
				(.action == "disallow" and has("os") and (.os | select(.name != "linux")))
			)
		else
			true
		end
	) | .downloads.classifiers."natives-linux".url | select(.)'
}

download_libs() {
	select_nonnative_urls | while read -r line; do
		bn="${line##*/}"

		if [ -e "libraries/$bn" ]; then
			warn "Using saved $bn"
			continue
		fi

		info "Downloading: $bn"
		scurl -fL "$line" -o "libraries/$bn"
	done

	select_native_urls | while read -r line; do
		# TODO: detect saved native libraries
		
		# This is a terrible hack, but is necessary.
		# Native library jars (actually zips) are extracted to ._, a
		# temporary directory.
		# META-INF is deleted and the contents of the zip that remains
		# gets copied into the native folder.

		bn="${line##*/}"

		# Make temp dir
		[ -e "._" ] && rm -rf ._
		mkdir ._

		# Download and extract
		info "Downloading native library: $bn"
		scurl -fL "$line" -o "._/$bn" || die "Failed to download $bn"
		cd ._
		unzip "$bn" || die "Failed to extract $bn"

		# Purge and pilfer
		rm -rf META-INF
		rm -f "$bn"
		cp -v * ../libraries/natives

		# Remove temp dir
		cd ..
		rm -rf ._
	done
}

fixup_libs() {
	# We only need to replace the libraries when we're on musl
	#
	# TODO: ARM. We need all new natives there.
	if [ ! -e "/lib/ld-musl-$(arch).so.1" ]; then
		return 0
	fi

	info "Replacing libraries..."

	for lib in libraries/natives/*.so; do
		bn="${lib##*/}"
		case "$bn" in
			libopenal.so|libopenal64.so)
				info "Replacing $bn"
				ncp /usr/lib/libopenal.so "$lib"
				;;
			libjemalloc.so)
				info "Replacing $bn"
				ncp /usr/lib/libjemalloc.so.2 "$lib"
				;;

			# This caused problems but me, but it may eventually be
			# useful for someone.
			#
			# libglfw.so|libglfw_wayland.so)
			# 	info "Replacing $bn"
			# 	ncp /usr/libraries/libglfw.so.3 "$lib"
			# 	;;
		esac
	done
}

fixup_log4j() {
	u="$(printf '%s' "$_VERCACHE" | jq -r .logging.client.file.url)"
	if [ "$u" != "null" ]; then
		# null if vulnerable to log4j exploit

		warn "Version is vulnerable to the Log4J exploit!"
		warn "Downloading fix."

		scurl -fL "$u" -o "log4j.xml"

		info "Patching Log4J configuration to restore sane console output"
		patch -p1 <<EOF || warn "Patch failed. Console output will be in XML."
--- a/log4j.xml
+++ b/log4j.xml
@@ -2,7 +2,7 @@
 <Configuration status="WARN">
     <Appenders>
         <Console name="SysOut" target="SYSTEM_OUT">
-            <XMLLayout />
+            <PatternLayout pattern="[%d{HH:mm:ss}] [%t/%level]: %msg%n" />
         </Console>
         <RollingRandomAccessFile name="File" fileName="logs/latest.log" filePattern="logs/%d{yyyy-MM-dd}-%i.log.gz">
             <PatternLayout pattern="[%d{HH:mm:ss}] [%t/%level]: %msg%n" />
EOF
	fi
}

download_game() {
	if [ -e "minecraft.jar" ]; then
		warn "Using existing minecraft.jar"
		return
	fi

	info "Downloading Minecraft..."
	scurl -fL "$(printf '%s' "$_VERCACHE" | jq -r ".downloads.client.url")" -o minecraft.jar
}

download_assets() {
	ai="$(printf '%s' "$_VERCACHE" | jq -r .assetIndex.url)"
	aid="$(printf '%s' "$_VERCACHE" | jq -r .assetIndex.id)"
	mkdir -p assets/indexes
	mkdir -p assets/objects
	echo "$aid" > .assetindex

	info "Downloading asset index..."
	scurl -fL "$ai" -o "assets/indexes/$aid.json"

	info "Downloading assets..."
	info "This may take a while."

	jq -r ".objects[].hash" < "assets/indexes/$aid.json" | while read -r obj; do
		dir="$(printf '%s' "$obj" | cut -c 1-2)"
		path="$dir/$obj"

		if [ ! -e "assets/objects/$dir" ]; then
			mkdir "assets/objects/$dir"
		elif [ -e "assets/objects/$path" ]; then
			warn "Using saved asset $obj"
			continue
		fi

		info "Downloading $obj"

		scurl -fL "$URL_ASR/$path" -o "assets/objects/$path"
	done
}

launch_game() {
	# Setup classpath.
	# Concat the path of every jar in lib to minecraft.jar.
	cp="minecraft.jar"

	for i in libraries/*.jar; do
		cp="$cp:$i"
	done

	# Chuck Log4J file onto JAVAOPTS if it's there
	if [ -e "log4j.xml" ]; then
		info "Using Log4J patch"
		JAVAOPTS="$JAVAOPTS -Dlog4j.configurationFile=log4j.xml"
	fi

	# OptiFine requires some extra setup and a different main class
	if [ -e "libraries/optifine" ]; then
		info "Detected OptiFine."

		XOPTS="--tweakClass optifine.OptiFineTweaker"
		MCLASS="net.minecraft.launchwrapper.Launch"

		# I'm sorry.
		for i in $(find libraries/optifine -type f -name "*.jar"); do
			cp="$cp:$i"
		done
	fi

	# This is when the game starts.
	# Java is executed with the classpath and the main class of Minecraft,
	# and pass some arguments (some of which dummy) to allow everything to
	# just work.
	exec java -Djava.library.path=libraries/natives $JAVAOPTS -cp "$cp" ${MCLASS:-"net.minecraft.client.main.Main"} \
		--accessToken "$(date +%s)" \
		--version "$(cat .version)" \
		--assetsDir assets \
		--assetIndex "$(cat .assetindex)" \
		--gameDir "$(pwd)" \
		--username "$USERNAME" \
		$XOPTS
}

if ! command -v jq >/dev/null; then
	die "jq is not installed and is required for mc.sh to work."
fi

if ! command -v curl >/dev/null; then
	die "curl is not installed and is required for mc.sh to download files."
fi

if ! command -v unzip >/dev/null; then
	die "unzip is not installed and is required for mc.sh to extract downloaded files."
fi

if ! command -v java >/dev/null; then
	die "java is not installed and is required for you to play the game."
fi

# Normal operation, user just wants to launch the game.
if [ "$#" -eq 0 ]; then
	if [ ! -e ".version" ]; then
		die "Minecraft is not installed. Select a version from './mc.sh list' and download it with './mc.sh <version>'."
	fi

	launch_game
fi

# list versions
if [ "$1" = "list" ]; then
	list_versions
	exit
elif [ "$1" = "optifine" ]; then
	if [ ! -e ".version" ]; then
		die "Minecraft is not installed yet!"
	fi

	info "Creating files to trick OptiFine into installing."
	info ""
	info "Instructions:"
	info "- Download OptiFine"
	info "- Launch the downloaded .jar file"
	info "- Point the directory at $(pwd)"
	info "- Click Install"
	info ""
	info "Once finished, run ./mc.sh ofclean"

	read v < .version
	mkdir -p "versions/$v" || true

	ln .verjson "versions/$v/$v.json"
	ln minecraft.jar "versions/$v/$v.jar"
	echo '{"profiles":{}}' > launcher_profiles.json

	exit
elif [ "$1" = "ofclean" ]; then
	if [ ! -e "versions" ]; then
		info "Nothing to clean up."
		exit
	fi

	info "Moving OptiFine to minecraft.jar"
	mv versions/*OptiFine*/*.jar minecraft.jar

	info "Removing temp files..."
	rm -rf versions launcher_profiles.json

	exit
fi

# User is downloading
if [ -e ".version" ]; then
	IFS= read v < .version
	if [ "$v" != "$1" ]; then
		die "v$v already installed here. Move to an empty directory or delete \".version\"."
	fi
	unset v
fi

_VERCACHE="$(fetch_ver "$1")"
printf '%s\n' "$_VERCACHE" > .verjson
printf '%s\n' "$1" > .version

info "Ensuring needed directories exist"
if [ ! -e "libraries" ]; then mkdir libraries; fi
if [ ! -e "libraries/natives" ]; then mkdir libraries/natives; fi

info "Downloading libraries..."
download_libs
fixup_libs

download_assets
fixup_log4j
download_game

info "Ready."
info "Start the game with ./mc.sh."
