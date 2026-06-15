# Stage 1: clone the upstream game source
# GIT_REF can be a branch, tag, or commit SHA.
# Default is "main" for the latest upstream content.
ARG GIT_REF=main

FROM alpine/git AS source
ARG GIT_REF
RUN git clone --depth 1 https://github.com/rohitg00/k8sgames.git /src \
    && if [ "${GIT_REF}" != "main" ]; then \
         cd /src \
         && git fetch --depth 1 origin "${GIT_REF}" \
         && git checkout FETCH_HEAD; \
       fi

# Stage 2: serve via nginx on port 8080 (non-root, OpenShift-compatible)
FROM nginxinc/nginx-unprivileged:alpine

COPY --from=source --chown=1001:0 /src/index.html  /usr/share/nginx/html/
COPY --from=source --chown=1001:0 /src/style.css   /usr/share/nginx/html/
COPY --from=source --chown=1001:0 /src/draw.html   /usr/share/nginx/html/
COPY --from=source --chown=1001:0 /src/js/         /usr/share/nginx/html/js/

EXPOSE 8080
