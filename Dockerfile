################# NVIDIA ##############
# NOTE: This Dockerfile is based on the official NVIDIA CUDA image.
# Usually there are 3 variants: base, runtime, devel.
# We are using the runtime variant, which is smaller than base but has more necessary
# dependencies used for building the application (more CUDA dependencies).
# We are intentionaly not using devel variant as it contains more dependencies than we need (mostly debug ones).
FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

ENV NV_CUDA_LIB_VERSION "12.2.0-1"

# NOTE: The following section is a stripped version of devel which is a bare minimum necessary for building the CUDA code.
# So in case something looks strange, please refer to the official NVIDIA CUDA image (https://gitlab.com/nvidia/container-images/cuda/-/blob/master/dist/12.2.0/ubuntu2204/devel/Dockerfile).
ENV NV_CUDA_CUDART_DEV_VERSION 12.2.53-1
ENV NV_NVML_DEV_VERSION 12.2.81-1
ENV NV_LIBCUSPARSE_DEV_VERSION 12.1.1.53-1
ENV NV_LIBNPP_DEV_VERSION 12.1.1.14-1
ENV NV_LIBNPP_DEV_PACKAGE libnpp-dev-12-2=${NV_LIBNPP_DEV_VERSION}

ENV NV_LIBCUBLAS_DEV_VERSION 12.2.1.16-1
ENV NV_LIBCUBLAS_DEV_PACKAGE_NAME libcublas-dev-12-2
ENV NV_LIBCUBLAS_DEV_PACKAGE ${NV_LIBCUBLAS_DEV_PACKAGE_NAME}=${NV_LIBCUBLAS_DEV_VERSION}

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    cuda-cudart-dev-12-2=${NV_CUDA_CUDART_DEV_VERSION} \
    cuda-command-line-tools-12-2=${NV_CUDA_LIB_VERSION} \
    cuda-minimal-build-12-2=${NV_CUDA_LIB_VERSION} \
    cuda-libraries-dev-12-2=${NV_CUDA_LIB_VERSION} \
    cuda-nvml-dev-12-2=${NV_NVML_DEV_VERSION} \
    ${NV_LIBNPP_DEV_PACKAGE} \
    ${NV_LIBCUBLAS_DEV_PACKAGE} \
    libcusparse-dev-12-2=${NV_LIBCUSPARSE_DEV_VERSION} \
    && rm -rf /var/lib/apt/lists/*

RUN apt-mark hold ${NV_LIBCUBLAS_DEV_PACKAGE_NAME}
ENV LIBRARY_PATH /usr/local/cuda/lib64/stubs
########################################

ENV DEBIAN_FRONTEND="noninteractive"
ENV TZ=UTC

WORKDIR /app

# Build and/or install FFmpeg dependencies
RUN apt-get update \
    && apt-get -y -q install --no-install-recommends \
    gcc \
    libva-dev libsdl2-dev wget autoconf \
    automake build-essential \
    libx264-dev yasm \
    curl unzip libncurses5-dev libssl-dev git sudo \
    && rm -rf /tmp/*

# Install Nvidia's codec sdk headers used by FFmpeg custom compilation
# NOTE: we are using the 12.0 version on purpose as otherwise FFmpeg failes to intitialize any nvidia decoder/encoder at runtime
RUN git clone -b n12.0.16.0 --depth 1 https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
    && cd nv-codec-headers && sudo make install && cd .. && rm -rf nv-codec-headers

# Clone and compile FFmpeg
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg/ \
    && cd ffmpeg && git checkout 284d1a8a6a2b8de2d5df7555232a086e2739c3d6 && \
    ./configure \
    --enable-nonfree \
    --enable-gpl \
    --enable-cuda-nvcc \
    --enable-libnpp \
    --enable-libx264 \
    --extra-cflags=-I/usr/local/cuda/include \
    --extra-ldflags=-L/usr/local/cuda/lib64 \
    --disable-static \
    --enable-shared \
    && make -j 8 && sudo make install \
    && cd .. && rm -rf ffmpeg


# Install necessary dependencies for building erlang and elixir (via asdf)
RUN apt-get update \
    && apt-get install -y software-properties-common \
    && add-apt-repository ppa:ubuntu-toolchain-r/test -y \
    && apt-get update \
    && apt-get install -y \
    autoconf \
    clang-format \
    libglib2.0-dev \
    libncurses-dev \
    libreadline-dev \
    libssl-dev \
    libtool \
    libxslt-dev \
    libyaml-dev \
    locales \
    unixodbc-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 \
    && git clone https://github.com/asdf-vm/asdf.git /root/.asdf -b v0.8.0

ENV PATH /root/.asdf/bin:/root/.asdf/shims:$PATH

# Erlang
RUN apt-get update \
    && apt-get install -y \
    autoconf \
    build-essential \
    fop \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    libncurses5-dev \
    libpng-dev \
    libssh-dev \
    m4 \
    unixodbc-dev \
    xsltproc \
    && rm -rf /var/lib/apt/lists/* \
    && asdf plugin-add erlang https://github.com/asdf-vm/asdf-erlang.git \
    && asdf install erlang 26.1 \
    && asdf global erlang 26.1 \
    && rm -rf /tmp/*

# Elixir
RUN asdf plugin-add elixir https://github.com/asdf-vm/asdf-elixir.git \
    && asdf install elixir 1.15.7-otp-26 \
    && asdf global elixir 1.15.7-otp-26 \
    && mix local.hex --force \
    && mix local.rebar --force \
    && rm -rf /tmp/*


# Make sure we are using Nvidia target when building the transcoder
ENV MIX_TARGET=nvidia

RUN mix local.hex --force \
    && mix local.rebar --force

# Set necessary paths when linking with FFmpeg
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig/pkgconfig:/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig/:$PKG_CONFIG_PATH
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:$LD_LIBRARY_PATH
ENV LC_ALL=C.UTF-8
