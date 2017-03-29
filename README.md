# Description #

This is a server that handles lookups of config values that are either in the file name given to start_link or in application:get_env.

* options:get/2 returns like application:get_env.

* values in the config file have precedence over the values in application:get_env.