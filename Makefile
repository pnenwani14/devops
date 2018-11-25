# Project Variables
ORG_NAME ?= nutanix
REPO_NAME ?= devops
VERSION ?= 0.1.$(BUILD_ID)

# Docker Compose Files
DEV_COMPOSE_FILE := docker/dev/docker-compose.yml
REL_COMPOSE_FILE := docker/release/docker-compose.yml

# Docker Compose Project Names
REL_PROJECT := $(REPO_NAME)$(BUILD_ID)
DEV_PROJECT := $(REL_PROJECT)dev

APP_SERVICE_NAME := nodejs

# Check and Inspect Logic
INSPECT := $$(docker-compose -p $$1 -f $$2 ps -q $$3 | xargs -I ARGS docker inspect -f "{{ .State.ExitCode }}" ARGS)
CHECK := @bash -c '\
	if [[ $(INSPECT) -ne 0 ]]; \
		then exit $(INSPECT); fi' VALUE


# Docker registry
DOCKER_REGISTRY ?= 

# Tags
TAGS := latest $(VERSION)

.PHONY: test build release clean tag buildtag login logout publish deploy

test:
	$(info "Creating cache volume...")
	@ docker volume create --name cache
	$(info "Pulling latest images...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) pull
	$(info "Building images...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) build --pull test
	$(info "Ensuring database is ready...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) run --rm agent
	$(info "Running tests...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) up test
	${CHECK} $(DEV_PROJECT) $(DEV_COMPOSE_FILE) test
	$(info "Testing complete")

build:
	$(info "Creating builder image...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) build builder
	$(info "Building application artifacts...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) up builder
	${CHECK} $(DEV_PROJECT) $(DEV_COMPOSE_FILE) builder
	$(info "Copying application artifacts...")
	@ docker cp $$(docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) ps -q builder):/output/nodejs-app.tar.gz target
	@ curl -uadmin:password -T target/nodejs-app.tar.gz "http://artifactory.gso.lab:8081/artifactory/devops-local-repo/$(REL_PROJECT)/nodejs-app.tar.gz"
	$(info "Copying web artifacts...")
	@ tar -C web/src/ -cvzf target/web.tar.gz .
	@ curl -uadmin:password -T target/web.tar.gz "http://artifactory.gso.lab:8081/artifactory/devops-local-repo/$(REL_PROJECT)/web.tar.gz"
	$(info "Copying db artifacts...")
	@ tar -C db/mongo/data/ -cvzf target/db.tar.gz .
	@ curl -uadmin:password -T target/db.tar.gz "http://artifactory.gso.lab:8081/artifactory/devops-local-repo/$(REL_PROJECT)/db.tar.gz"
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) down -v
	$(info "Build complete")

release:
	$(info "Pulling latest images...")
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSE_FILE) build nodejs
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSE_FILE) run --rm agent
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSE_FILE) run -d nodejs
	$(info "Acceptance testing complete")

clean:
	$(info "Destroying development environment...")
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) down -v
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSE_FILE) down -v
	$(info "Removing dangling images...")
	@ docker images -q -f dangling=true -f label=application=$(REPO_NAME) | xargs -I ARGS docker rmi -f ARGS
	$(info "Clean complete")

tag: 
	$(info "Tagging release image with tags...")
	@ $(foreach tag,$(TAGS), docker tag $(IMAGE_ID) $(DOCKER_REGISTRY)/$(ORG_NAME)/$(REPO_NAME):$(tag);)
	$(info "Tagging complete")

login:
	$(info "Logging in to Docker registry $(DOCKER_REGISTRY)...")
	@ docker login -u $$DOCKER_REGISTRY_USER -p $$DOCKER_REGISTRY_PASSWORD $(DOCKER_REGISTRY)
	$(info "Logged in to Docker registry $(DOCKER_REGISTRY)")

logout:
	$(info "Logging out of Docker registry $(DOCKER_REGISTRY)...")
	@ docker logout $(DOCKER_REGISTRY)
	$(info "Logged out of Docker registry $(DOCKER_REGISTRY)")

publish:
	$(info "Publishing release image $(IMAGE_ID) to $(DOCKER_REGISTRY)/$(ORG_NAME)/$(REPO_NAME)...")
	@ $(foreach tag,$(shell echo $(REPO_EXPR)), docker push $(tag);)
	$(info "Publish complete")

# Get container id of application service container
APP_CONTAINER_ID := $$(docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSE_FILE) ps -q $(APP_SERVICE_NAME))

# Get image id of application service
IMAGE_ID := $$(docker inspect -f '{{ .Image }}' $(APP_CONTAINER_ID))

# REPO FILTER
REPO_FILTER := $(DOCKER_REGISTRY)/$(ORG_NAME)/$(REPO_NAME)[^[:space:]|\$$]*

# Introspect repository tags
REPO_EXPR := $$(docker inspect -f '{{range .RepoTags}}{{.}} {{end}}' $(IMAGE_ID) | grep -oh "$(REPO_FILTER)" | xargs)

