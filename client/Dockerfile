# ---------- Build Stage ----------
ARG NODE_VERSION=22.17-alpine3.22
ARG NGINX_VERSION=alpine3.21

FROM node:${NODE_VERSION} AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY . .
RUN npm run build


# ---------- Runtime Stage ----------
FROM nginxinc/nginx-unprivileged:${NGINX_VERSION} AS runner

USER root

# Copy custom nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Copy build output
COPY --from=builder /app/dist /usr/share/nginx/html

# Ensure nginx owns the whole html directory
RUN chown -R nginx:nginx /usr/share/nginx/html

# Copy entrypoint script
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/

USER nginx

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
