#!/bin/sh
# Runs a celld application as a Unikraft unikernel on this machine.
#
#   unikraft/run-local.sh [PROJECT]       default: examples/counter
#
# 1. A local S3 (moto) starts in Docker and holds the fleet bucket.
# 2. Docker builds celld for linux/amd64 and packs it into an initrd.
# 3. `celld deploy` writes PROJECT into the bucket from a container.
# 4. `kraft run` boots celld on QEMU. The guest reaches the bucket through
#    QEMU's host address, 10.0.2.2, and serves the application on PORT.
#
# The unikernel keeps no state that matters: cells live in the bucket, so you
# can stop it and boot it again and the data is still there, for as long as
# the S3 container runs.
#
# Needs Docker, KraftKit and QEMU: `brew install unikraft/cli/kraftkit qemu`.
#
# Environment:
#   PORT=8080          host port of the application
#   MEMORY=1Gi         unikernel memory
#   S3_PORT=9000       host port of the local S3
#   SKIP_BUILD=1       reuse the initrd and images of the last run
#   KEEP_S3=1          leave the local S3 running when the unikernel stops
#   EMULATED_BUILD=1   compile celld inside an emulated linux/amd64 container
#                      instead of cross-compiling (slow, but no cross toolchain)
#
# To use a real bucket instead (R2, S3, Tigris), set all four of
#   CELLD_BUCKET=s3://NAME  S3_ENDPOINT=https://...  AWS_ACCESS_KEY_ID  AWS_SECRET_ACCESS_KEY
# and optionally AWS_REGION. The script then starts no local S3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
project=$(cd "${1:-$root/examples/counter}" && pwd)
port=${PORT:-8080}
memory=${MEMORY:-1Gi}
s3_port=${S3_PORT:-9000}
network=celld-unikraft
s3=celld-unikraft-s3
deployer=celld-unikraft-deployer:local
s3_image=celld-unikraft-s3:local

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Install $1 first: $2"; }

need docker "Docker Desktop, OrbStack or colima"
need kraft "brew install unikraft/cli/kraftkit"
need qemu-system-x86_64 "brew install qemu"
need curl "your package manager"
docker info >/dev/null 2>&1 || fail "Docker does not answer. Start Docker Desktop, OrbStack or colima."

if [ -n "${CELLD_BUCKET:-}" ]; then
  if [ -z "${S3_ENDPOINT:-}" ] || [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    fail "With CELLD_BUCKET, also set S3_ENDPOINT, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
  fi
  local_s3=0
  bucket_spec=$CELLD_BUCKET
  region=${AWS_REGION:-auto}
  deploy_endpoint=$S3_ENDPOINT
  guest_endpoint=$S3_ENDPOINT
  access_key=$AWS_ACCESS_KEY_ID
  secret_key=$AWS_SECRET_ACCESS_KEY
else
  local_s3=1
  bucket_spec=s3://cells
  region=us-east-1
  deploy_endpoint=http://$s3:9000
  guest_endpoint=http://10.0.2.2:$s3_port
  access_key=celld
  secret_key=celld-unikraft
fi

if [ "${SKIP_BUILD:-0}" != 1 ] || [ ! -f "$here/.build/rootfs.cpio" ]; then
  build_stage=build
  [ "${EMULATED_BUILD:-0}" = 1 ] && build_stage=build-emulated
  step "Building the celld initrd (linux/amd64, $build_stage)"
  docker build --platform linux/amd64 -f "$here/Dockerfile" --build-arg "CELLD_BUILD=$build_stage" \
    --target initrd --output "type=local,dest=$here/.build" "$root"
  step "Building the deployer image"
  docker build --platform linux/amd64 -f "$here/Dockerfile" --build-arg "CELLD_BUILD=$build_stage" \
    --target deployer -t "$deployer" "$root"
  if [ "$local_s3" = 1 ]; then
    step "Building the local S3 image"
    docker build -f "$here/Dockerfile" --target s3 -t "$s3_image" "$root"
  fi
fi

docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
if [ "$local_s3" = 1 ]; then
  step "Starting the local S3 on 127.0.0.1:$s3_port"
  if [ -z "$(docker ps -q -f "name=^${s3}$")" ]; then
    docker rm -f "$s3" >/dev/null 2>&1 || true
    docker run -d --name "$s3" --network "$network" -p "127.0.0.1:$s3_port:9000" "$s3_image" >/dev/null
  fi
  tries=0
  until curl -fs -o /dev/null "http://127.0.0.1:$s3_port/"; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || fail "The local S3 did not start. See: docker logs $s3"
    sleep 1
  done
  # Creating a bucket that exists answers 409, which is fine.
  status=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    --aws-sigv4 "aws:amz:$region:s3" --user "$access_key:$secret_key" \
    "http://127.0.0.1:$s3_port/cells")
  case "$status" in 200|409) ;; *) fail "Creating the bucket answered HTTP $status" ;; esac
  echo "  bucket $bucket_spec ready"
fi

step "Deploying $project"
docker run --rm --platform linux/amd64 --network "$network" \
  -v "$project:/app" -w /app \
  -e "AWS_ACCESS_KEY_ID=$access_key" -e "AWS_SECRET_ACCESS_KEY=$secret_key" \
  "$deployer" deploy . --bucket "$bucket_spec" --endpoint "$deploy_endpoint" --region "$region"

cleanup() {
  if [ "$local_s3" = 1 ] && [ "${KEEP_S3:-0}" != 1 ]; then docker stop "$s3" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

step "Booting the unikernel"
accel=""
# An x86_64 guest on an Apple silicon host has no hardware acceleration.
[ "$(uname -m)" = x86_64 ] || accel="--disable-acceleration"
echo "  The application answers on http://127.0.0.1:$port once celld serves. Ctrl-C stops it."
# shellcheck disable=SC2086
kraft run --rm --plat qemu --arch x86_64 $accel -M "$memory" \
  -p "$port:8080" \
  -e "CELLD_BUCKET=$bucket_spec" \
  -e "S3_ENDPOINT=$guest_endpoint" \
  -e "AWS_REGION=$region" \
  -e "AWS_ACCESS_KEY_ID=$access_key" \
  -e "AWS_SECRET_ACCESS_KEY=$secret_key" \
  "$here"
