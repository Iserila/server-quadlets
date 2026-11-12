# Crab Fit frontend (Next.js) built from source. Upstream only deploys it to
# Vercel, so there's no Dockerfile for it. NEXT_PUBLIC_API_URL is inlined into
# the client bundle at build time, so it's a build arg, not a runtime env var.

FROM docker.io/library/node:18-bookworm-slim AS builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
ARG CRABFIT_REF=628f9eefc300bf1ed3d6cc3323332c2ed9b8a350
ARG NEXT_PUBLIC_API_URL
ARG FRONTEND_URL
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/GRA0007/crab.fit.git \
 && git fetch -q --depth 1 origin "$CRABFIT_REF" \
 && git checkout -q FETCH_HEAD
WORKDIR /src/frontend
# Dev defaults (API on 127.0.0.1), don't let them leak into the build.
RUN rm -f .env.local
# Share links and metadataBase are hardcoded to https://crab.fit, point them at this instance.
RUN sed -i 's#https://crab\.fit/\${#'"$FRONTEND_URL"'/${#g' \
      'src/app/[id]/page.tsx' \
      src/components/CreateForm/components/EventInfo/EventInfo.tsx \
 && sed -i "s#new URL('https://crab.fit')#new URL('$FRONTEND_URL')#" src/app/layout.tsx \
 && ! grep -rn "https://crab\.fit/\${\|new URL('https://crab\.fit')" src
RUN yarn install --frozen-lockfile && yarn build

FROM docker.io/library/node:18-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY --from=builder /src/frontend /app
EXPOSE 3000
CMD ["yarn", "start"]
