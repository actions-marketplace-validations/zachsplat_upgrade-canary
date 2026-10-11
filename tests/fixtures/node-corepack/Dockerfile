# The common node:lts plus corepack pattern. Node 26 images ship without
# corepack, so this breaks when node:lts moves to Node 26.
FROM node:lts-slim
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
WORKDIR /app
COPY package.json index.js ./
RUN corepack enable && pnpm install
EXPOSE 3000
CMD ["node", "index.js"]
