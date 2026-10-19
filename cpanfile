requires "Dancer2" => "0.161000";
requires "Dancer2::Plugin::Database" => "0";
requires "Dancer2::Plugin::Ajax" => "0";
requires "Dancer2::Session::Memcached" => "0";
requires "Dancer2::Template::TemplateToolkit" => "0";
requires "Template" => "0"; # Template Toolkit itself (Template::Plugin::Date/JSON come with it)
requires "Plack" => "0";
requires "Plack::Handler::Starman" => "0";
requires "Pg::hstore" => "0";
requires "Cache::Memcached" => "0"; # session backend + /login and /api/auth/ rate limiting
requires "Net::LDAP" => "0";
requires "Net::LDAP::Extension::SetPassword" => "0";
requires "Crypt::YAPassGen" => "0"; # generates new accounts' initial passwords
requires "JSON::XS" => "0";
requires "HTML::Entities" => "0";
requires "HTML::Strip" => "0";
requires "String::ShellQuote" => "0"; # every route that shells out (ffmpeg/opusenc/wget/curl/tesseract/identify) depends on this for safe quoting -- do not remove
requires "URI::Encode" => "0";
requires "Digest::SHA" => "0";
requires "Text::CSV" => "0";

recommends "YAML"             => "0";
recommends "YAML::XS"         => "0";
recommends "URL::Encode::XS"  => "0";
recommends "CGI::Deurl::XS"   => "0";
recommends "HTTP::Parser::XS" => "0";

on "test" => sub {
    requires "Test::More"            => "0";
    requires "HTTP::Request::Common" => "0";
};
