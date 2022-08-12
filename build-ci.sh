#!/usr/bin/env bash

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Cancel if environtment not ready
if [[ -z "$GIT_TOKEN" ]] || [[ -z "$1" ]]; then
    err "Something is missing!"
fi

# Install dependency
bash ci.sh deps

# Set a directory
DIR="$(pwd ...)"

# Setup branch
BRANCH="$1"

# Cancel if clang is already made for today
check_build_date() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    wget -q https://raw.githubusercontent.com/XSans0/WeebX-Clang/main/build-date.txt -O date.txt 1>/dev/null 2>/dev/null || echo 'nothing' > date.txt

    if [[ "$(cat date.txt)" == "$(TZ=Asia/Jakarta date +"%Y-%m-%d")" ]]; then
        msg "Clang is already made for today"
        rm -rf date.txt
        exit
    fi
}

# Go Check
check_build_date

# Build LLVM
extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

msg "Building LLVM..."
./build-llvm.py \
	--clang-vendor "WeebX" \
	--defines "LLVM_PARALLEL_COMPILE_JOBS=$(nproc) LLVM_PARALLEL_LINK_JOBS=$(nproc) CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3" \
	--projects "clang;compiler-rt;lld;polly" \
	--targets "ARM;AArch64;X86" \
	--shallow-clone \
	--incremental \
    --branch "${BRANCH}" "${extra_args[@]}"

# Check if the final clang binary exists or not.
for file in install/bin/clang-1*
do
  if [ -e "$file" ]
  then
    msg "Clang build successfully"
  else 
    err "Clang build failed!"
    exit
  fi
done

# Build binutils
msg "Building binutils..."
./build-binutils.py --targets arm aarch64 x86_64

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
ZipName="WeebX-Clang-$clang_version-${TagsDate}.tar.gz"
Tags="WeebX-Clang-$clang_version-${TagsDate}-release"
ClangLink="https://github.com/XSans0/WeebX-Clang/releases/download/${Tags}/${ZipName}"

# Git Config
git config --global user.name "XSans0"
git config --global user.email "xsansdroid@gmail.com"

pushd install || exit
{
    echo "# Quick Info
* Build Date : $(TZ=Asia/Jakarta date +"%Y-%m-%d")
* Clang Version : $clang_version
* Binutils Version : $binutils_ver
* Compiled Based : $llvm_commit_url"
} >> README.md
tar -czvf ../"$ZipName" /*
popd || exit

# Clone Repo
git clone "https://XSans0:$GIT_TOKEN@github.com/XSans0/WeebX-Clang.git" rel_repo
pushd rel_repo || exit
echo "${ClangLink}" > "$clang_version"-link.txt
"$(TZ=Asia/Jakarta date +"%Y-%m-%d")" > build-date.txt
git add .
git commit -asm "WeebX-Clang-$clang_version: ${TagsDate}"
git tag "${Tags}" -m "${Tags}"
git push -f origin main
git push -f origin "${Tags}"
popd || exit

chmod +x github-release
./github-release release \
    --security-token "$GIT_TOKEN" \
    --user XSans0 \
    --repo WeebX-Clang \
    --tag "${Tags}" \
    --name "${Tags}" \
    --description "$(cat install/README.md)"

fail="n"
./github-release upload \
    --security-token "$GIT_TOKEN" \
    --user XSans0 \
    --repo WeebX-Clang \
    --tag "${Tags}" \
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
    git push -d origin "${Tags}"
    git reset --hard HEAD~1
    git push -f origin main
    popd || exit
fi