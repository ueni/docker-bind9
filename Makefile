include assembly.info

IMAGE:=ueniueni/docker-bind9
VERSION:=$(VERSION_MAJOR).$(VERSION_FEATURE).$(VERSION_BUGFIX).$(VERSION_BUILD)

.PHONY: tag
tag: build
	@[ "${VERSION}" ] || ( echo "Env var VERSION is not set."; exit 1 )
	docker tag $(IMAGE) $(IMAGE):$(VERSION)
	docker tag $(IMAGE) $(IMAGE):latest

.PHONY: release
release: tag
	@[ "${VERSION}" ] || ( echo "Env var VERSION is not set."; exit 1 )
	docker push $(IMAGE):$(VERSION)
	docker push $(IMAGE):latest

.PHONY: build
build:
	docker build --progress=plain -t $(IMAGE) .

.PHONY: run
run: build
	@docker run \
		--rm \
		$(IMAGE):latest
