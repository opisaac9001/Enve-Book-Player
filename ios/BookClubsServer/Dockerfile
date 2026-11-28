FROM node:24-bookworm-slim
WORKDIR /app
RUN mkdir /data && chown node:node /data
COPY --chown=node:node src ./src
COPY --chown=node:node migrations ./migrations
COPY --chown=node:node public ./public
COPY --chown=node:node protocol ./protocol
ENV BOOK_CLUB_HOST=0.0.0.0 BOOK_CLUB_PORT=8794 BOOK_CLUB_DATABASE=/data/book-club.sqlite
USER node
EXPOSE 8794
HEALTHCHECK --interval=30s --timeout=5s CMD ["node", "-e", "fetch('http://127.0.0.1:8794/v1/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
CMD ["node", "src/homelab/server.mjs"]
