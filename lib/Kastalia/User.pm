package Kastalia::User;
#use Dancer2::Plugin::Database;
#use Net::SMTP::TLS;
#use JSON::XS;
our $VERSION = '0.1';

use Dancer2 appname => 'Kastalia::Main'; #appname important to interconnect modules!

my $account_admins=config->{account_admins};
#my $ldp_heslo=config->{ldap_pass};
#my $ldp_base=config->{ldap_base};
#my $ldp_ou=config->{ldap_ou};
#my $ldp_cn=config->{ldap_bind_cn};
#my $ldp_domain=config->{ldap_domain};


sub valid_creator {
	 my $creator_mail=shift @_;
	 # was /($account_admins)/ -- an unanchored substring match, so any
	 # login merely CONTAINING "root" or "daniel-hromada" anywhere (e.g.
	 # "approot", "daniel-hromada2") would incorrectly pass this admin
	 # gate (create LDAP accounts, force-reset other users' passwords).
	 # Anchor to an exact match against one of the configured admin names.
	 if ($creator_mail !~ /^(?:$account_admins)$/) {
		debug "SECWARN User::valid_creator $creator_mail unknown";
		Kastalia::Main::rdrct('/user_constructor','',"You are not (yet) allowed to invite people. Specify a valid registrator account or ask Your colleagues (administrator has been already notified).");
	}
	return true;
}

sub account_exists {
	my $account = shift @_;
	my $ldap = shift @_;
	my $result = $ldap->search ( base    => config->{ldap_base},scope   => "sub",filter  => "cn=$account");
	if ($result->entries) {
		return true;
		#Kastalia::Main::rdrct('/user_constructor','',"$account is already registered. Please change name or surname.");
	}
	return false;
}

sub ou_short {
	my $ou = shift @_;
	$ou =~ s/^ou=//;
	return $ou;
}

sub available_ous {
	return [
		{ value => ou_short(config->{ldap_ou1}), label => config->{ldap_label1}, ou => config->{ldap_ou1}, domain => config->{ldap_domain1} },
		{ value => ou_short(config->{ldap_ou2}), label => config->{ldap_label2}, ou => config->{ldap_ou2}, domain => config->{ldap_domain2} },
	];
}

get qr{/user_constructor/?} => sub {
	debug 'USER'.session 'user';
	debug session;
	template 'user_constructor',{'err'=>(session 'err'),'registrar_login'=> (session 'user'),'ous'=>available_ous()};
};

post qr{/newpwd} => sub {
	my %ou_by_value = map { $_->{value} => $_ } @{available_ous()};
	my $chosen = $ou_by_value{param 'ou'} // $ou_by_value{ou_short(config->{ldap_ou1})};
	my $ldap_ou = $chosen->{ou};
	debug "OU $ldap_ou";

	use Net::LDAP;
	my $ldap=Net::LDAP->new(config->{ldap_host});

	my $mesg = $ldap->bind("cn=".params->{login}.",$ldap_ou,".config->{ldap_base},password => params->{pwd});
	if ($mesg->code!=0) {
		Kastalia::Main::rdrct('/newpwd','',"Authentication failed. SysOp notified.");
	}

	debug $mesg;
	use Net::LDAP::Extension::SetPassword;
	debug "cn=".params->{login}.",$ldap_ou,".config->{ldap_base};
	my $new_pwd=param 'new_pwd';
	$mesg = $ldap->set_password(user=>"cn=".params->{login}.",$ldap_ou,".config->{ldap_base}, newpasswd => $new_pwd );
	Kastalia::Main::rdrct('/newpwd',"Your password is now <b>$new_pwd</b>",'');
};

get qr{/newpwd/?} => sub {
	debug 'USER'.session 'user';
	debug session;
	template 'newpwd',{'err'=>(session 'err'),'msg'=>(session 'msg'),'registrar_login'=> (session 'user'),'ous'=>available_ous()};
};
get qr{/user_resetpwd/?} => sub {
	debug 'USER'.session 'user';
	debug session;
	template 'user_resetpwd',{'err'=>(session 'err'),'msg'=>(session 'msg'),'registrar_login'=> (session 'user'),'ous'=>available_ous()};
};



post qr{/user_constructor/?} => sub {
	my $account=lc(param "login");
	$account =~ s/^\s+|\s+$//g;

	if (!$account or $account !~ /^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/) {
		Kastalia::Main::rdrct('/user_constructor','',"Invalid login. Use only letters, numbers, dot, dash or underscore.");
	}

	my %ou_by_value = map { $_->{value} => $_ } @{available_ous()};
	my $chosen = $ou_by_value{param 'ou'} // $ou_by_value{ou_short(config->{ldap_ou1})};
	my $ldap_ou = $chosen->{ou};
	my $mail_domain = $chosen->{domain};
	debug "OU $ldap_ou";

	my $creator_mail=session('login');
	debug "SUBMIT $creator_mail wants to create $account in $ldap_ou";
	use Net::LDAP;
	my $ldap=Net::LDAP->new(config->{ldap_host});
	my $mesg = $ldap->bind(config->{ldap_bind_cn}.','.config->{ldap_base},password => config->{ldap_pass} ,version => 3 );
        debug $mesg;
	if (account_exists($account,$ldap)) {
		Kastalia::Main::rdrct('/user_constructor','',"$account is already registered. Please choose a different login.");
	}
	if (valid_creator($creator_mail)) {
		debug "creating cn=$account,$ldap_ou";
		my $result = $ldap->add ("cn=$account,$ldap_ou,".config->{ldap_base}, attrs => [objectClass=>'inetOrgPerson',mail=>$account."@".$mail_domain,sn=>$account,uid=>$account,cn=>$account] );
		use Crypt::YAPassGen;
		debug("cn=$account,$ldap_ou,".config->{ldap_base});
		debug $result;
		my $passgen=Crypt::YAPassGen->new(length=>9);
		my $password=$passgen->generate();
		#set LDAP password
		use Net::LDAP::Extension::SetPassword;
		$mesg = $ldap->set_password(user=>"cn=$account,$ldap_ou,".config->{ldap_base}, newpasswd => $password );
		debug $mesg;
		debug "$account PASS $password";

		my $user_knot =  Kastalia::Main::addKnot($account,"Profile of $account\n",{"type"=>"human"});	
		Kastalia::Main::addBound(session('user_id'),'registered',$user_knot);
		Kastalia::Main::rdrct('/last',"Account registered, please transfer the sequence <b>$password</b> to $account by secure means.");
	}
};


post qr{/user_resetpwd/?} => sub {
	my $account=lc(param "login");
	$account =~ s/^\s+|\s+$//g;

	if (!$account) {
		Kastalia::Main::rdrct('/user_resetpwd','',"Invalid login.");
	}

	my %ou_by_value = map { $_->{value} => $_ } @{available_ous()};
	my $chosen = $ou_by_value{param 'ou'} // $ou_by_value{ou_short(config->{ldap_ou1})};
	my $ldap_ou = $chosen->{ou};

	debug "OU $ldap_ou";
	my $creator_mail=session('login');
	debug "SUBMIT $creator_mail wants to updated password for $account";
	use Net::LDAP;
	my $ldap=Net::LDAP->new(config->{ldap_host});
	my $msg = $ldap->bind(config->{ldap_bind_cn}.','.config->{ldap_base},password => config->{ldap_pass} ,version => 3 ); 
	#my $mesg = $ldap->bind("cn=".params->{login}.",ou=".params->{ou},password => params->{pwd});
        debug $msg;
	if (valid_creator($creator_mail) && account_exists($account,$ldap)) {
		use Crypt::YAPassGen;
		my $passgen=Crypt::YAPassGen->new(length=>9);
		my $password=$passgen->generate();
		#set LDAP password
		use Net::LDAP::Extension::SetPassword;
		$msg = $ldap->set_password(user=>"cn=$account,$ldap_ou,".config->{ldap_base}, newpasswd => $password );
		debug $msg;
		debug "cn=$account,$ldap_ou,".config->{ldap_base}." PASS $password";
		Kastalia::Main::rdrct('/last',"Password changed, please transfer the sequence <b>$password</b> to $account by secure means.");
	}
};


true;
