#!/usr/bin/env bash

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Environment checker
if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT" ] || [ -z "$BRANCH" ] || [ -z "$GIT_TOKEN" ]; then
    err "* Incomplete environment!"
    exit
fi

# Set a home directory
HOME_DIR="$(pwd)"

# Telegram Setup
git clone --depth=1 https://github.com/XSans0/Telegram Telegram

TELEGRAM="$HOME_DIR/Telegram/telegram"
send_msg() {
  "${TELEGRAM}" -H -D \
      "$(
          for POST in "${@}"; do
              echo "${POST}"
          done
      )"
}

send_file() {
    "${TELEGRAM}" -H \
    -f "$1" \
    "$2"
}

# Build LLVM
msg "Building LLVM..."
send_msg "<b>Clang build started on <code>[ $BRANCH ]</code> branch</b>"
./build-llvm.py \
    --branch "$BRANCH" \
    --clang-vendor "WeebX" \
    --defines LLVM_PARALLEL_COMPILE_JOBS=$(nproc) LLVM_PARALLEL_LINK_JOBS=$(nproc) CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3 \
    --no-ccache \
    --quiet-cmake \
    --shallow-clone \
    --targets "ARM;AArch64" 2>&1 | tee "$HOME_DIR/log.txt"

# Check if the final clang binary exists or not.
for file in install/bin/clang-1*
do
    if [ -e "$file" ]
    then
        msg "LLVM building successful"
    else 
        err "LLVM build failed!"
        send_file "$HOME_DIR/log.txt" "<b>Clang build failed on <code>[ $BRANCH ]</code> branch</b>"
        exit
    fi
done

# Build binutils
msg "Building binutils..."
./build-binutils.py --targets arm aarch64

# Remove unused products
rm -fr install/include
rm -f install/lib/*.a install/lib/*.la

# Strip remaining products
for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
	strip -s "${f: : -1}"
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
	# Remove last character from file output (':')
	bin="${bin: : -1}"

	echo "$bin"
	patchelf --set-rpath "$DIR/../lib" "$bin"
done

# Release Info
pushd llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<< "$llvm_commit")"
popd || exit

llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
binutils_ver="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"
TagsDate="$(TZ=Asia/Jakarta date +"%Y%m%d")"
BuildDate="$(TZ=Asia/Jakarta date +"%Y-%m-%d")"
BuildHours="$(TZ=Asia/Jakarta date +"%H%M")"
ZipName="WeebX-Clang-$clang_version-$TagsDate-$BuildHours.tar.gz"
Tags="WeebX-Clang-$clang_version-$TagsDate-$BuildHours-release"
ClangLink="https://github.com/XSans0/WeebX-Clang/releases/download/$Tags/$ZipName"

# Git Config
git config --global user.name "XSans0"
git config --global user.email "xsansdroid@gmail.com"

pushd install || exit
{
    echo "# Quick Info
* Build Date : $BuildDate
* Clang Version : $clang_version
* Binutils Version : $binutils_ver
* Compiled Based : $llvm_commit_url"
} >> README.md
tar -czvf ../"$ZipName" .
popd || exit

# Push
git clone "https://XSans0:$GIT_TOKEN@github.com/XSans0/WeebX-Clang.git" rel_repo
pushd rel_repo || exit
if [ -d "$BRANCH" ]; then
    echo "$ClangLink" > "$BRANCH"/link.txt
    cp -r ../install/README.md "$BRANCH"
else
    mkdir -p "$BRANCH"
    echo "$ClangLink" > "$BRANCH"/link.txt
    cp -r ../install/README.md "$BRANCH"
fi
git add .
git commit -asm "WeebX-Clang-$clang_version: $TagsDate"
git tag "$Tags" -m "$Tags"
git push -f origin main
git push -f origin "$Tags"
popd || exit

# Upload to github release
chmod +x github-release
./github-release release \
    --security-token "$GIT_TOKEN" \
    --user XSans0 \
    --repo WeebX-Clang \
    --tag "$Tags" \
    --name "$Tags" \
    --description "$(cat install/README.md)"

fail="n"
./github-release upload \
    --security-token "$GIT_TOKEN" \
    --user XSans0 \
    --repo WeebX-Clang \
    --tag "$Tags" \
    --name "$ZipName" \
    --file "$ZipName" || fail="y"

TotalTry="0"
UploadAgain()
{
    GetRelease="$(./github-release upload \
        --security-token "$GIT_TOKEN" \
        --user XSans0 \
        --repo WeebX-Clang \
        --tag "${Tags}" \
        --name "$ZipName" \
        --file "$ZipName")"
    [[ -z "$GetRelease" ]] && fail="n"
    [[ "$GetRelease" == *"already_exists"* ]] && fail="n"
    TotalTry=$((TotalTry+1))
    if [ "$fail" == "y" ];then
        if [ "$TotalTry" != "5" ];then
            sleep 10s
            UploadAgain
        fi
    fi
}
if [ "$fail" == "y" ];then
    sleep 10s
    UploadAgain
fi

if [ "$fail" == "y" ];then
    pushd rel_repo || exit
    git push -d origin "$Tags"
    git reset --hard HEAD~1
    git push -f origin main
    popd || exit
fi

# Send message to telegram
send_file "$HOME_DIR/log.txt" "<b>Clang build successful on <code>[ $BRANCH ]</code> branch</b>"
send_msg "
<b>----------------- Quick Info -----------------</b>
<b>Build Date : </b>
* <code>$BuildDate</code>
<b>Clang Version : </b>
* <code>$clang_version</code>
<b>Binutils Version : </b>
* <code>$binutils_ver</code>
<b>Compile Based : </b>
* <a href='$llvm_commit_url'>$llvm_commit_url</a>
<b>Push Repository : </b>
* <a href='https://github.com/XSans0/WeebX-Clang.git'>WeebX-Clang</a>
<b>--------------------------------------------------</b>"