package JSON::Validator::Store;
use Mojo::Base -base;

use Carp 'confess';
use Mojo::File 'path';
use JSON::Validator::Util 'data_section';

use constant CASE_TOLERANT   => File::Spec->case_tolerant;
use constant DEBUG           => $ENV{JSON_VALIDATOR_DEBUG} || 0;
use constant RECURSION_LIMIT => $ENV{JSON_VALIDATOR_RECURSION_LIMIT} || 100;
use constant YAML_SUPPORT    => eval 'use YAML::XS 0.67;1';

my $BUNDLED_CACHE_DIR = path(__FILE__)->sibling('cache');

has cache_paths => sub {
  Mojo::Util::deprecated('ua() is replaced by $jv->store->ua()');
  return [split(/:/, $ENV{JSON_VALIDATOR_CACHE_PATH} || ''),
    $BUNDLED_CACHE_DIR];
};

has schemas => sub { +{} };

has ua => sub {
  require Mojo::UserAgent;
  my $ua = Mojo::UserAgent->new;
  $ua->proxy->detect;
  $ua->max_redirects(3);
  $ua;
};

sub add_schema {
  my ($self, $id, $schema) = @_;
  $id =~ s!(.)#$!$1!;
  $self->schemas->{$id} = $schema;
  return $self;    # TODO: Return $schema instead?
}

sub get_schema { $_[0]->schemas->{$_[1]} }

sub load_schema {
  my ($self, $url) = @_;

  if ($url =~ m!^https?://!) {
    warn "[JSON::Validator] Loading schema from URL $url\n" if DEBUG;
    return $self->load_schema_from_url(Mojo::URL->new($url)->fragment(undef)),
      "$url";
  }

  if ($url =~ m!^data://([^/]*)/(.*)!) {
    my ($class, $file) = ($1, $2);
    my $text = data_section $class, $file, {confess => 1, encoding => 'UTF-8'};
    return $self->load_schema_from_text(\$text), "$url";
  }

  if ($url =~ m!^\s*[\[\{]!) {
    warn "[JSON::Validator] Loading schema from string.\n" if DEBUG;
    return $self->load_schema_from_text(\$url), '';
  }

  my $file = $url;
  $file =~ s!^file://!!;
  $file =~ s!#$!!;
  $file = path(split '/', $file);
  if (-e $file) {
    $file = $file->realpath;
    warn "[JSON::Validator] Loading schema from file: $file\n" if DEBUG;
    return $self->load_schema_from_text(\$file->slurp),
      CASE_TOLERANT ? path(lc $file) : $file;
  }
  elsif ($url =~ m!^/! and $self->ua->server->app) {
    warn "[JSON::Validator] Loading schema from URL $url\n" if DEBUG;
    return $self->load_schema_from_url(Mojo::URL->new($url)->fragment(undef)),
      "$url";
  }

  confess "Unable to load schema '$url' ($file)";
}

sub load_schema_from_text {
  my ($self, $text) = @_;

  # JSON
  return Mojo::JSON::decode_json($$text) if $$text =~ /^\s*\{/s;

  # YAML
  die "[JSON::Validator] YAML::XS 0.67 is missing or could not be loaded."
    unless YAML_SUPPORT;

  no warnings 'once';
  local $YAML::XS::Boolean = 'JSON::PP';
  return YAML::XS::Load($$text);
}

sub load_schema_from_url {
  my ($self, $url) = @_;
  my $cache_path = $self->cache_paths->[0];
  my $cache_file = Mojo::Util::md5_sum("$url");

  for (@{$self->cache_paths}) {
    my $path = path $_, $cache_file;
    warn "[JSON::Validator] Looking for cached spec $path ($url)\n" if DEBUG;
    next unless -r $path;
    return $self->load_schema_from_text(\$path->slurp);
  }

  my $tx  = $self->ua->get($url);
  my $err = $tx->error && $tx->error->{message};
  confess "GET $url == $err"               if DEBUG and $err;
  die "[JSON::Validator] GET $url == $err" if $err;

  if ($cache_path
    and
    ($cache_path ne $BUNDLED_CACHE_DIR or $ENV{JSON_VALIDATOR_CACHE_ANYWAYS})
    and -w $cache_path)
  {
    $cache_file = path $cache_path, $cache_file;
    warn "[JSON::Validator] Caching $url to $cache_file\n"
      unless $ENV{HARNESS_ACTIVE};
    $cache_file->spurt($tx->res->body);
  }

  return $self->load_schema_from_text(\$tx->res->body);
}

1;
