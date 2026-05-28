IMAGE ?= efa-exporter-pod
TAG ?= 2.0.0

build:
	docker build -t $(IMAGE):$(TAG) .

push: build
	docker push $(IMAGE):$(TAG)

run:
	docker run -d \
		--net="host" \
		--pid="host" \
		-v "/:/host:ro,rslave" \
		-v "/var/lib/kubelet/pod-resources:/var/lib/kubelet/pod-resources:ro" \
		$(IMAGE):$(TAG) \
		--path.rootfs=/host

.PHONY: build push run
