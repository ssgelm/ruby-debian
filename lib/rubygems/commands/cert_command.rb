require 'rubygems/command'
require 'rubygems/security'
require 'openssl'

class Gem::Commands::CertCommand < Gem::Command

  def initialize
    super 'cert', 'Manage RubyGems certificates and signing settings',
          :add => [], :remove => [], :list => [], :build => [], :sign => []

    OptionParser.accept OpenSSL::X509::Certificate do |certificate|
      begin
        OpenSSL::X509::Certificate.new File.read certificate
      rescue Errno::ENOENT
        raise OptionParser::InvalidArgument, "#{certificate}: does not exist"
      rescue OpenSSL::X509::CertificateError
        raise OptionParser::InvalidArgument,
          "#{certificate}: invalid X509 certificate"
      end
    end

    OptionParser.accept OpenSSL::PKey::RSA do |key_file|
      begin
        key = OpenSSL::PKey::RSA.new File.read key_file
      rescue Errno::ENOENT
        raise OptionParser::InvalidArgument, "#{key_file}: does not exist"
      rescue OpenSSL::PKey::RSAError
        raise OptionParser::InvalidArgument, "#{key_file}: invalid RSA key"
      end

      raise OptionParser::InvalidArgument,
            "#{key_file}: private key not found" unless key.private?

      key
    end

    add_option('-a', '--add CERT', OpenSSL::X509::Certificate,
               'Add a trusted certificate.') do |cert, options|
      options[:add] << cert
    end

    add_option('-l', '--list [FILTER]',
               'List trusted certificates where the',
               'subject contains FILTER') do |filter, options|
      filter ||= ''

      options[:list] << filter
    end

    add_option('-r', '--remove FILTER',
               'Remove trusted certificates where the',
               'subject contains FILTER') do |filter, options|
      options[:remove] << filter
    end

    add_option('-b', '--build EMAIL_ADDR',
               'Build private key and self-signed',
               'certificate for EMAIL_ADDR') do |email_address, options|
      options[:build] << email_address
    end

    add_option('-C', '--certificate CERT', OpenSSL::X509::Certificate,
               'Signing certificate for --sign') do |cert, options|
      options[:issuer_cert] = cert
    end

    add_option('-K', '--private-key KEY', OpenSSL::PKey::RSA,
               'Key for --sign or --build') do |key, options|
      options[:key] = key
    end

    add_option('-s', '--sign CERT',
               'Signs CERT with the key from -K',
               'and the certificate from -C') do |cert_file, options|
      raise OptionParser::InvalidArgument, "#{cert_file}: does not exist" unless
        File.file? cert_file

      options[:sign] << cert_file
    end
  end

  def execute
    options[:add].each do |certificate|
      Gem::Security.trust_dir.trust_cert certificate

      say "Added '#{certificate.subject}'"
    end

    options[:remove].each do |filter|
      certificates_matching filter do |certificate, path|
        FileUtils.rm path
        say "Removed '#{certificate.subject}'"
      end
    end

    options[:list].each do |filter|
      certificates_matching filter do |certificate, _|
        # this could probably be formatted more gracefully
        say certificate.subject.to_s
      end
    end

    options[:build].each do |name|
      build name
    end

    unless options[:sign].empty? then
      load_default_cert unless options[:issuer_cert]
      load_default_key  unless options[:key]
    end

    options[:sign].each do |cert_file|
      sign cert_file
    end
  end

  def build name
    key = options[:key] || Gem::Security.create_key

    cert = Gem::Security.create_cert_email name, key

    key_path  = Gem::Security.write key, "gem-private_key.pem"
    cert_path = Gem::Security.write cert, "gem-public_cert.pem"

    say "Certificate: #{cert_path}"
    say "Private Key: #{key_path}"
    say "Don't forget to move the key file to somewhere private!"
  end

  def certificates_matching filter
    return enum_for __method__, filter unless block_given?

    Gem::Security.trusted_certificates.select do |certificate, _|
      subject = certificate.subject.to_s
      subject.downcase.index filter
    end.sort_by do |certificate, _|
      certificate.subject.to_a.map { |name, data,| [name, data] }
    end.each do |certificate, path|
      yield certificate, path
    end
  end

  def description # :nodoc:
    <<-EOF
The cert command manages signing keys and certificates for creating signed
gems.  Your signing certificate and private key are typically stored in
~/.gem/gem-public_cert.pem and ~/.gem/gem-private_key.pem respectively.

To build a certificate for signing gems:

  gem cert --build you@example

If you already have an RSA key, or are creating a new certificate for an
existing key:

  gem cert --build you@example --private-key /path/to/key.pem

If you wish to trust a certificate you can add it to the trust list with:

  gem cert --add /path/to/cert.pem

You can list trusted certificates with:

  gem cert --list

or:

  gem cert --list cert_subject_substring

If you wish to remove a previously trusted certificate:

  gem cert --remove cert_subject_substring

To sign another gem author's certificate:

  gem cert --sign /path/to/other_cert.pem

For further reading on signing gems see `ri Gem::Security`.
    EOF
  end

  def load_default_cert
    cert_file = File.join Gem.user_home, 'gem-public_cert.pem'
    cert = File.read cert_file
    options[:issuer_cert] = OpenSSL::X509::Certificate.new cert
  rescue Errno::ENOENT
    alert_error \
      "--certificate not specified and ~/.gem/gem-public_cert.pem does not exist"

    terminate_interaction 1
  rescue OpenSSL::X509::CertificateError
    alert_error \
      "--certificate not specified and ~/.gem/gem-public_cert.pem is not valid"

    terminate_interaction 1
  end

  def load_default_key
    key_file = File.join Gem.user_home, 'gem-private_key.pem'
    key = File.read key_file
    options[:key] = OpenSSL::PKey::RSA.new key
  rescue Errno::ENOENT
    alert_error \
      "--private-key not specified and ~/.gem/gem-private_key.pem does not exist"

    terminate_interaction 1
  rescue OpenSSL::PKey::RSAError
    alert_error \
      "--private-key not specified and ~/.gem/gem-private_key.pem is not valid"

    terminate_interaction 1
  end

  def sign cert_file
    cert = File.read cert_file
    cert = OpenSSL::X509::Certificate.new cert

    permissions = File.stat(cert_file).mode & 0777

    issuer_cert = options[:issuer_cert]
    issuer_key = options[:key]

    cert = Gem::Security.sign cert, issuer_key, issuer_cert

    Gem::Security.write cert, cert_file, permissions
  end

end

