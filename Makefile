.PHONY: all kernel clean_kernel run

all: kernel root.img

root.tar: Dockerfile init Cargo.lock Cargo.toml $(shell find src) $(shell find tokio-uring/src) $(shell find tini)
	sh -c "DOCKER_BUILDKIT=1 docker build -o type=tar,dest=root.tar ."

root.img: root.tar
	qemu-img create root.img 3G
	mkfs.ext4 root.img
	mkdir root
	@echo "We need to temporary mount the root.img to add all the files from the docker container to it. This requires root permissions."
	sudo mount root.img root
	sudo tar -xf root.tar -C root
	sudo umount root
	rmdir root

linux/arch/x86/boot/bzImage: linux/.config
	$(MAKE) -C linux -j 4 LOCALVERSION=-custom

kernel: linux/arch/x86/boot/bzImage

clean_kernel:
	rm linux/arch/x86/boot/bzImage

run: linux/arch/x86/boot/bzImage root.img
	qemu-system-x86_64 \
		-M microvm,x-option-roms=off,pit=off,pic=off,rtc=off \
		-no-acpi -enable-kvm -cpu host -m 512m -smp 2 \
		-nodefaults -no-user-config -nographic -no-reboot \
		-device virtio-rng-device \
		-serial stdio \
		-enable-kvm \
		-kernel linux/arch/x86/boot/bzImage \
		-drive id=root,file=root.img,format=raw,cache=none,if=none \
		-device virtio-blk-device,drive=root \
		-append "console=ttyS0 acpi=off root=/dev/vda rw reboot=t panic=-1 quiet loglevel=-1"
