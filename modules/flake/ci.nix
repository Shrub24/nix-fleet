# This repository's own CI, through the interface it publishes (modules/ci).
_: {
  ci = {
    retention.generations = 3;
    # Daily, ahead of the consumers: this lock is the shared inputs they follow.
    updates = {
      when = {
        minute = 43;
        hour = [ 3 ];
      };
      autoMerge = true;
    };
  };
}
