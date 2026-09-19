# The image `count.sh` runs `count.py` in: the pinned Swift toolchain plus Valgrind.
# python3-minimal because the swift image ships no Python and count.py is the driver.
FROM swift:6.3.3
RUN apt-get update \
 && apt-get install -y --no-install-recommends valgrind python3-minimal \
 && rm -rf /var/lib/apt/lists/*
