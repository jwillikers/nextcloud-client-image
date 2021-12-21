#!/usr/bin/env fish

set -l options (fish_opt --short a --long architecture --required-val)
set -a options (fish_opt --short c --long cachedir --required-val)
set -a options (fish_opt --short m --long manifest --required-val)
set -a options (fish_opt --short n --long name --required-val)
set -a options (fish_opt --short v --long version --required-val)
set -a options (fish_opt --short h --long help)

argparse --max-args 0 $options -- $argv
or exit

set -l default_architecture (buildah info --format={{".host.arch"}})
set -l example_cachedir /var/cache/dnf
set -l default_name nextcloud-client
set -l default_nextcloud_version 3.4.1

if set -q _flag_help
    echo "build.fish [-a|--architecture $default_architecture] [-c|--cachedir $example_cachedir] [-h|--help] [-m|--manifest manifest-name] [-n|--name $default_name] [-v|--version $default_nextcloud_version]"
    exit 0
end

set -l architecture $default_architecture
if set -q _flag_architecture
    set architecture $_flag_architecture
end
echo "The image will be built for the $architecture architecture."

set -l cachedir_option
if set -q _flag_cachedir
    set -l cachedir_option --volume $_flag_cachedir:/var/cache/dnf:O
    echo "Caching DNF packages in $cachedir."
end

# todo: Create initial cachedir if empty.
# https://www.redhat.com/sysadmin/speeding-container-buildah

if set -q _flag_manifest
    set -l manifest $_flag_manifest
    echo "The image will be added to the $manifest manifest."
end

set -l name $default_name
if set -q _flag_name
    set name $_flag_name
end

set -l fedora_version 35

set -l nextcloud_version $default_nextcloud_version
if set -q _flag_version
    set nextcloud_version $_flag_version
end

#set -l build_container (buildah from --arch $architecture registry.fedoraproject.org/fedora:latest)
set -l build_container (buildah from --arch $architecture scratch)
set -l build_container_mountpoint (buildah mount $build_container)

podman run --rm --arch $architecture --volume $build_container_mountpoint:/mnt:z $cachedir_option registry.fedoraproject.org/fedora:latest \
    sh -c "dnf -y install --installroot /mnt --releasever $fedora_version --nodocs \
        bash cmake gcc gcc-c++ git gold ninja-build \
        openssl-devel libzip-devel qt5-qtbase-devel qt5-qtbase-private-devel qt5-qtdeclarative-devel \
        qt5-qtwebengine-devel qtkeychain-qt5-devel qt5-qttools-devel qt5-qtsvg-devel \
        qt5-qtwebsockets-devel qt5-qtquickcontrols2-devel \
        shared-mime-info sqlite-devel zlib-devel; \
        dnf clean all -y --installroot /mnt --releasever $fedora_version"
or exit

podman run --rm --arch $architecture --volume $build_container_mountpoint:/mnt:z registry.fedoraproject.org/fedora:latest \
    sh -c "useradd --root /mnt nextcloud-client-builder"
or exit

buildah unmount $build_container
or exit

#buildah run $build_container -- sh -c "dnf -y install \
#        bash cmake gcc gcc-c++ git gold ninja-build \
#        openssl-devel libzip-devel qt5-qtbase-devel qt5-qtbase-private-devel qt5-qtdeclarative-devel \
#        qt5-qtwebengine-devel qtkeychain-qt5-devel qt5-qttools-devel qt5-qtsvg-devel \
#        qt5-qtwebsockets-devel qt5-qtquickcontrols2-devel \
#        shared-mime-info sqlite-devel zlib-devel \
#        --nodocs"

#buildah run $build_container -- \
#    sh -c "dnf clean all -y"
#or exit

#buildah run $build_container -- \
#    sh -c "useradd nextcloud-client-builder"
#or exit

buildah config --user nextcloud-client-builder $build_container
or exit

buildah run $build_container -- sh -c 'git -C /home/nextcloud-client-builder clone https://github.com/nextcloud/desktop.git'
or exit

buildah config --workingdir /home/nextcloud-client-builder/desktop $build_container
or exit

buildah run $build_container -- sh -c "git checkout v$nextcloud_version"
or exit

buildah run $build_container -- sh -c 'cmake -GNinja \
  -DCMAKE_INSTALL_PREFIX=/home/nextcloud-client-builder/nextcloud-desktop-client \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_UNITY_BUILD=yes \
  -DCMAKE_POLICY_DEFAULT_CMP0069=NEW \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=yes \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=gold" \
  -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=gold" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=gold" \
  -DBUILD_SHELL_INTEGRATION=no \
  -DBUILD_SHELL_INTEGRATION_ICONS=no \
  -DBUILD_SHELL_INTEGRATION_DOLPHIN=no \
  -DBUILD_SHELL_INTEGRATION_NAUTILUS=no \
  -DBUILD_GUI=no \
  -DMIRALL_VERSION_SUFFIX="" \
  -B build \
  -S .'
or exit

buildah run $build_container -- sh -c 'cmake --build build'
or exit

buildah run $build_container -- sh -c 'cmake --install build'
or exit

set -l container (buildah from --arch $architecture scratch)
set -l container_mountpoint (buildah mount $container)

podman run --rm --arch $architecture --volume $container_mountpoint:/mnt:z $cachedir_option registry.fedoraproject.org/fedora:latest \
    sh -c "dnf -y install --installroot /mnt --releasever $fedora_version --nodocs --setopt install_weak_deps=False \
    glibc-minimal-langpack \
    qt5-qtbase qt5-qtsvg qt5-qtwebsockets qtkeychain-qt5 sqlite; \
    dnf clean all -y --installroot /mnt --releasever $fedora_version"
or exit

podman run --rm --arch $architecture --volume $container_mountpoint:/mnt:z registry.fedoraproject.org/fedora:latest \
    sh -c "useradd --root /mnt nextcloud-client"
or exit

buildah unmount $container
or exit

buildah copy --from $build_container $container /home/nextcloud-client-builder/nextcloud-desktop-client/ /
or exit

buildah config --user nextcloud-client $container
or exit

buildah config --workingdir /home/nextcloud-client $container
or exit

buildah config --entrypoint '["/usr/bin/nextcloudcmd"]' $container
or exit

buildah config --label io.containers.autoupdate=registry $container
or exit

buildah config --author jordan@jwillikers.com $container
or exit

buildah config --arch $architecture $container
or exit

if set -q manifest
    buildah commit --rm --squash --manifest $manifest $container $name
    or exit
else
    buildah commit --rm --squash $container $name
    or exit
end

buildah tag $name $version
