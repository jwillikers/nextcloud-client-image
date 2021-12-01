#!/usr/bin/env fish

set -l options (fish_opt --short a --long architecture --required-val)
set -a options (fish_opt --short m --long manifest --required-val)
set -a options (fish_opt --short n --long name --required-val)
set -a options (fish_opt --short h --long help)

argparse --max-args 0 $options -- $argv
or exit

if set -q _flag_help
    echo "build.fish [-a|--architecture] [-h|--help] [-m|--manifest] [-n|--name]"
    exit 0
end

set -l architecture (buildah info --format={{".host.arch"}})
if set -q _flag_architecture
    set architecture $_flag_architecture
end
echo "The image will be built for the $architecture architecture."

if set -q _flag_manifest
    set -l manifest $_flag_manifest
    echo "The image will be added to the $manifest manifest."
end

set -l name forticlient
if set -q _flag_name
    set name $_flag_name
end

set -l container (buildah from --arch $architecture scratch)
set -l mountpoint (buildah mount $container)

podman run --rm --arch $architecture --volume $mountpoint:/mnt:Z registry.fedoraproject.org/fedora:latest \
    bash -c "dnf -y install --installroot /mnt --releasever 35 glibc-minimal-langpack bash coreutils nextcloud-client --nodocs --setopt install_weak_deps=False"
or exit

podman run --rm --arch $architecture --volume $mountpoint:/mnt:Z registry.fedoraproject.org/fedora:latest \
    bash -c "dnf clean all -y --installroot /mnt --releasever 35"
or exit

buildah unmount $container
or exit

buildah config --cmd '["bash"]' $container
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
