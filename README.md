# Caboose

Track what just happened in your Rails app.

A Laravel Telescope-style debugging dashboard for Rails. Development-focused, local-first, captures everything happening in your app and displays it with a waterfall visualization.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "caboose"
```

Then execute:

```bash
bundle install
```

If you want to tweak config, then run the install generator to create an initializer:

```bash
rails generate caboose:install
```

## Usage

Click around in your Rails app and then visit `/caboose` in your browser to see the dashboard.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jnunemaker/caboose.
