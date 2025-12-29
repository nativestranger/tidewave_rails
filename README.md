# Tidewave

Tidewave is the coding agent for full-stack web app development. Integrate Claude Code, OpenAI Codex, and other agents with your web app and web framework at every layer, from UI to database. [See our website](https://tidewave.ai) for more information.

This project can also be used as a standalone Model Context Protocol server for your editors.

## Installation

You can install Tidewave by running:

```shell
bundle add tidewave --group development
```

or by manully adding the `tidewave` gem to the development group in your Gemfile:

```ruby
gem "tidewave", group: :development
```

Now make sure [Tidewave is installed](https://hexdocs.pm/tidewave/installation.html) and you are ready to connect Tidewave to your app.

## Troubleshooting

### Using multiple hosts/subdomains

If you are using multiple hosts/subdomains during development, you must use `*.localhost`, as such domains are considered secure by browsers. Additionally, add the following to `config/initializers/development.rb`:

```ruby
config.session_store :cookie_store,
  key: "__your_app_session",
  same_site: :none,
  secure: true,
  assume_ssl: true
```

And make sure you are using `rack-session` version `2.1.0` or later.

The above will allow your application to run embedded within Tidewave across multiple subdomains, as long as it is using a secure context (such as `admin.localhost`, `www.foobar.localhost`, etc).

### Content security policy

If you have enabled Content-Security-Policy, Tidewave will automatically enable "unsafe-eval" under `script-src` in order for contextual browser testing to work correctly. It also disables the `frame-ancestors` directive.

### Production Environment

Tidewave is a powerful tool that can help you develop your web application faster and more efficiently. However, it is important to note that Tidewave is not meant to be used in a production environment.

Tidewave will raise an error if it is used in any environment where code reloading is disabled (which typically includes production).

## Configuration

You may configure `tidewave` using the following syntax:

```ruby
  config.tidewave.team = { id: "my-company" }
```

The following config is available:

  * `allow_remote_access` - Tidewave only allows requests from localhost by default, even if your server listens on other interfaces. If you trust your network and need to access Tidewave from a different machine, this configuration can be set to `true`

  * `logger_middleware` - The logger middleware Tidewave should wrap to silence its own logs

  * `preferred_orm` - which ORM to use, either `:active_record` (default) or `:sequel`

  * `team` - set your Tidewave Team configuration, such as `config.tidewave.team = { id: "my-company" }`

## Features

### Async Job Logging

Tidewave provides structured logging for async-job executions, filling the visibility gap for async-job's memory/Redis adapter (which has no UI or persistence, unlike SolidQueue's Mission Control or Sidekiq's Web UI).

**Two separate log files for optimal signal-to-noise:**
- `async_job_exceptions.log` - Failed jobs only (small, scannable, critical)
- `async_job_runs.log` - All executions (optional, for performance analysis)

**Opt-in configuration** in your `config/initializers/tidewave.rb`:

```ruby
Rails.application.config.tidewave.tap do |config|
  # ... existing tidewave config ...
  
  # Async job logging (only for async-job adapter)
  config.async_job_log_exceptions = true  # Always log failures
  config.async_job_log_runs = true        # Optional: log all executions
  
  # Configure paths (important for Docker deployments with volumes)
  # Default: Rails.root/log/async_job_exceptions.log
  # For persistent volumes, point to volume-mounted directory:
  # config.async_job_exceptions_file = '/mnt/data/log/async_job_exceptions.log'
  # config.async_job_runs_file = '/mnt/data/log/async_job_runs.log'
  
  # Optional: customize rotation
  # config.async_job_exceptions_max_size = 5.megabytes
  # config.async_job_exceptions_rotations = 2
  # config.async_job_runs_max_size = 10.megabytes
  # config.async_job_runs_rotations = 1
  
  # Optional: customize logger formatter and level
  # config.async_job_logger_formatter = proc { |severity, datetime, progname, msg| "#{msg}\n" }
  # config.async_job_logger_level = Logger::INFO
  
  # Optional: provide your own Logger instances (most flexible)
  # config.async_job_exceptions_logger = Logger.new(STDOUT)
  # config.async_job_runs_logger = Logger.new(STDOUT)
end
```

**Logger configurability** (three levels of control):

1. **Provide custom logger instances** (full control):
   ```ruby
   config.async_job_exceptions_logger = MyCustomLogger.new
   config.async_job_runs_logger = AnotherLogger.new
   ```

2. **Customize formatter and level** (uses default Logger with your settings):
   ```ruby
   config.async_job_logger_formatter = proc { |severity, datetime, progname, msg|
     "[#{datetime}] #{severity}: #{msg}\n"
   }
   config.async_job_logger_level = Logger::DEBUG
   ```

3. **Use smart defaults** (just enable and go):
   ```ruby
   config.async_job_log_exceptions = true
   # Uses sensible defaults for file paths, rotation, formatting
   ```

**Accessing logs via MCP:**
- Tool: `get_async_job_logs`
- Parameters: `tail` (count), `grep` (filter), `source` ('exceptions' or 'runs')
- Returns structured JSON with job class, duration, arguments, backtraces

**Why separate logs?**
1. Exceptions stay small and scannable (find failures fast)
2. Runs log doesn't drown out critical errors  
3. Different rotation needs (keep exceptions longer)
4. Faster MCP parsing (small exception log = fast response)

**Docker deployments with persistent volumes:**

For containerized deployments, configure paths to point to volume-mounted directories to persist logs across container restarts:

```ruby
# config/initializers/tidewave.rb
if ENV['USE_MOUNTED_VIBES'] == 'true'
  config.async_job_log_exceptions = true
  config.async_job_log_runs = ENV['LOG_SUCCESSFUL_JOBS'] == 'true'
  
  # Point to persistent volume (not ephemeral container filesystem)
  config.async_job_exceptions_file = '/mnt/data/code/log/async_job_exceptions.log'
  config.async_job_runs_file = '/mnt/data/code/log/async_job_runs.log'
end
```

**Note:** SolidQueue jobs are already tracked in database tables and don't need additional logging.

## Acknowledgements

A thank you to Yorick Jacquin, for creating [FastMCP](https://github.com/yjacquin/fast_mcp) and implementing the initial version of this project.

## License

Copyright (c) 2025 Dashbit

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
