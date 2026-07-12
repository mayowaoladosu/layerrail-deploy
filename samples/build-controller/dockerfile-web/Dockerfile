FROM node@sha256:a0b9bf06e4e6193cf7a0f58816cc935ff8c2a908f81e6f1a95432d679c54fbfd
WORKDIR /app
RUN test "$(awk '/CapEff/ { print $2 }' /proc/self/status)" = "0000000000000000"
RUN test ! -e /run/lrail-build \
	&& test ! -e /var/run/secrets/kubernetes.io/serviceaccount \
	&& test ! -e /state \
	&& test ! -e /work
COPY isolation-probe.mjs ./isolation-probe.mjs
RUN node isolation-probe.mjs
COPY --chown=node:node server.js ./server.js
ENV NODE_ENV=production PORT=8000
USER node
EXPOSE 8000
CMD ["node", "server.js"]
