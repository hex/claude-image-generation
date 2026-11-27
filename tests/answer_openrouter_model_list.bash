# ABOUTME: Sourced first by a test's curl stub: answers the image model list openrouter.sh reads to
# ABOUTME: pick its endpoint from a fixture, and leaves every other request to the stub.
case "$*" in
  *"https://openrouter.ai/api/v1/models?output_modalities=image"*)
    cat "$(dirname "${BASH_SOURCE[0]}")/fixtures/openrouter/image-models.json"
    printf '\n200\n'
    exit 0 ;;
esac
