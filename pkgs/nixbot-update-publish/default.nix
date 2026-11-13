# Opens or updates the update pull request after the scheduled effect pushed its branch.
{ writers }:
writers.writePython3Bin "nixbot-update-publish" {
  # ruff formats this repository's Python; the writer's 79-column default is not its convention.
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./publish.py)
