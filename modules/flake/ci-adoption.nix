# This repository's own CI, through the interface it publishes.
_: {
  ci = {
    retention.generations = 3;
    updates.when = {
      minute = 43;
      hour = [ 4 ];
    };
  };
}
