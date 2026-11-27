# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t pianus .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name pianus pianus

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base runtime packages:
# - SQLite (primary database + Solid Queue / Solid Cache / Solid Cable)
# - Audio/video tools (ffmpeg, yt-dlp) and Python (for audio transcription)
# - Headless Java + Tesseract OCR (for Audiveris OMR) and unzip (for .mxl archives)
# - curl, libvips (Active Storage variants), and jemalloc (reduced memory usage)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    curl \
    ffmpeg \
    libgtk-3-0t64 \
    libjemalloc2 \
    libvips \
    default-jre-headless \
    python3 \
    python3-pip \
    sqlite3 \
    unzip \
    yt-dlp && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    AUDIVERIS_BIN="/usr/local/bin/audiveris" \
    TESSDATA_PREFIX="/opt/audiveris/tessdata" \
    BASIC_PITCH_BIN="/usr/local/bin/basic-pitch" \
    YTDLP_BIN="/usr/bin/yt-dlp"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and node modules
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config unzip && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH
ARG BUN_VERSION=1.4.5
RUN curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION}"

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Install node modules
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile


RUN rm -rf node_modules


# Final stage for app image
FROM base

# Install Audiveris 5.11.0 OMR from official release package, legacy Tesseract 4.x tessdata (eng + por), and audio CLI wrapper
ARG AUDIVERIS_DEB_URL="https://github.com/Audiveris/audiveris/releases/download/5.11.0/Audiveris-5.11.0-ubuntu24.04-x86_64.deb"
ARG TESSDATA_BASE_URL="https://github.com/tesseract-ocr/tessdata/raw/main"
RUN curl -fsSL -o /tmp/audiveris.deb "${AUDIVERIS_DEB_URL}" && \
    dpkg-deb -x /tmp/audiveris.deb / && \
    rm -f /tmp/audiveris.deb && \
    ln -sf /opt/audiveris/bin/Audiveris /usr/local/bin/audiveris && \
    mkdir -p /opt/audiveris/tessdata && \
    curl -fsSL -o /opt/audiveris/tessdata/eng.traineddata "${TESSDATA_BASE_URL}/eng.traineddata" && \
    curl -fsSL -o /opt/audiveris/tessdata/por.traineddata "${TESSDATA_BASE_URL}/por.traineddata" && \
    printf '#!/usr/bin/env bash\nexec python3 -m basic_pitch "$@"\n' > /usr/local/bin/basic-pitch && \
    chmod +x /usr/local/bin/basic-pitch

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80 3000
CMD ["./bin/thrust", "./bin/rails", "server"]
