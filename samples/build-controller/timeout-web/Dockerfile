FROM node@sha256:a0b9bf06e4e6193cf7a0f58816cc935ff8c2a908f81e6f1a95432d679c54fbfd
WORKDIR /app
RUN sleep 300
COPY --chown=node:node server.js ./server.js
ENV NODE_ENV=production PORT=8000
USER node
EXPOSE 8000
CMD ["node", "server.js"]
