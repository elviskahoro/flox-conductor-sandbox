#!/usr/bin/env bash
# Generate bisect probe files for the Conductor cloud 403-on-paste problem
# (see ../SKILL.md). Probes are meant to be pasted one at a time into the
# install script field; a 403 means the filter rejected the text, anything
# else (builds, or a syntax-error exit because the file is cut mid-function)
# means the text was accepted.
#
# Usage:
#   make-bisect-probes.sh prefix <script> <out_dir> <bytes>...
#   make-bisect-probes.sh lines  <script> <out_dir> <first_line> <last_line>
set -euo pipefail

mode="${1:-}"
script="${2:-}"
out="${3:-}"
if [[ -z "${mode}" || -z "${script}" || -z "${out}" || ! -f "${script}" ]]; then
  echo "usage: $0 prefix|lines <script> <out_dir> <args...>" >&2
  exit 2
fi
shift 3
mkdir -p "${out}"

case "${mode}" in
prefix)
  for n in "$@"; do
    # Drop the last (possibly partial) line so no line is cut mid-text.
    head -c "${n}" "${script}" | sed '$d' >"${out}/bisect-${n}b.sh"
    echo "${out}/bisect-${n}b.sh ($(wc -c <"${out}/bisect-${n}b.sh") bytes)"
  done
  ;;
lines)
  first="${1:?first_line required}"
  last="${2:?last_line required}"
  f="${out}/segment-${first}-${last}.sh"
  { echo "echo segment-${first}-${last}"; sed -n "${first},${last}p" "${script}"; } >"${f}"
  echo "${f} ($(wc -c <"${f}") bytes)"
  ;;
*)
  echo "unknown mode: ${mode}" >&2
  exit 2
  ;;
esac
