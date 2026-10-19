use HTML::Entities;
use utf8;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use Encode qw(encode); 

use URI::Encode qw(uri_decode uri_encode);

ajax qr{/api/memcache/(\w+)/(\w+)} => sub {
     my ($key,$value) = splat;
     session $key=>$value;
     debug "$value stored into $key";
     return $value;
};

ajax qr{/api/memcache_uri/(.*)/(.*)} => sub {
     my ($key,$value) = splat;
     session $key=>uri_decode($value);
     debug "$value stored into $key";
     return uri_encode($value);
};


ajax qr{/api/error/(\d+)/(\d+)?} => sub {
     my ($error_id,$illustration_id) = splat;
     my $errors=session('errors');
     #here, an upsert bound for illustrations would be much much nicer
     #addZeitgeist($user_id,$error_id,"TEST",{"state"=>"ERR","IMG"=>$illustration_id});
     session "errors"=>($errors.$error_id.":::");
};
 
ajax qr{/api/correct/(\d+)/(\d+)?} => sub {
     my ($correct_id,$illustration_id) = splat;
     my $corrects=session('corrects');
     #here, an upsert bound for illustrations would be much much nicer
     addZeitgeist($user_id,'/'.$correct_id,"TEST",{"state"=>"CORRECT","IMG"=>$illustration_id});
     session "corrects"=>($corrects.$correct_id.":::");
};

ajax qr{/api/submit_learn/} => sub {
     my $user_id=session('user_id');
     my $knot_id=session('knot_id');
     addZeitgeist($user_id,$knot_id,"LEARN",{"state"=>"COMPLETE"});
};

ajax qr{/api/submit_test/} => sub {
     my $user_id=session('user_id');
     my $knot_id=session('knot_id');
     my $corrects=session('corrects');
     my $errors=session('errors');
     my $n_corrects=0;
     my $n_errors=scalar split(/:::/,$errors);
     for my $correct_id (split(/:::/,$corrects)) {
		     upsertBound($user_id,'misunderstands',$correct_id,0.5,"*",0.5,"HMPL correct");
		     $n_corrects++;
     }
     addZeitgeist($user_id,"$knot_id","TEST",{"state"=>"COMPLETE","corrects"=>$corrects,"n_corrects"=>$n_corrects,"errors"=>$errors,"n_errors"=>$n_errors});
     session 'errors'=>"";
     session 'corrects'=>"";
     return $corrects;
};
  
ajax qr{/api/get_illustrations_simple/(\d+)?/?} => sub {
     my $self = shift;
     my ($knot_id) = splat;
	my $q="select string_agg(distinct illustration.attributes->'img_url','::') as illustration_urls from bounds left join knots as illustration on illustration.knot_id=bounds.sub and bounds.predicate='illustrates' where bounds.obj=?";
	debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	my $res=$sth->fetchrow_hashref();
	my $pics=$res->{'illustration_urls'};
	$pics=~s/::/","/g;
	utf8::encode($pics);
	return ('["'.$pics.'"]');
};    

ajax qr{/api/get_illustrations/(\d+)?/?} => sub {
     my $self = shift;
     my ($knot_id) = splat;
	my $q="select string_agg(distinct illustration.attributes->'img_url','::') as illustration_urls from bounds as parent_bound left join knots as parent on parent.knot_id=parent_bound.sub and (parent_bound.predicate='is_parent' or parent_bound.predicate='is_uttered_as') left join knots as child on child.knot_id=parent_bound.obj left join bounds as illustration_bound on parent.knot_id=illustration_bound.obj and illustration_bound.predicate='illustrates' left join knots as illustration on illustration.knot_id=illustration_bound.sub where parent_bound.obj=?";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	my $res=$sth->fetchrow_hashref();
	my $pics=$res->{'illustration_urls'};
	$pics=~s/::/","/g;
	utf8::encode($pics);
	return ('["'.$pics.'"]');
};    
ajax qr{/api/get_illustration_direct/(\d+)?/?} => sub {
     my $self = shift;
     my ($knot_id) = splat;
	my $q="select json_agg(distinct illustration.attributes->'img_url') as illustration_urls from bounds as illustration_bound left join knots as illustration on illustration.knot_id=illustration_bound.sub where illustration_bound.obj=? and illustration_bound.predicate='illustrates'";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	my $res=$sth->fetchrow_hashref();
	#my $pics=$res->{'illustration_urls'};
	#$pics=~s/::/","/g;
	#utf8::encode($pics);
	utf8::encode($res->{'illustration_urls'});
	return ($res->{'illustration_urls'});
};    


ajax qr{/api/increment_score/(\d+)} => sub {
	my ($score)=splat;
	#debug "SCORE INCREMENT for ".session('user_id');
	my $sth=database('knots')->prepare("update knots set attributes = attributes || hstore('score', ((attributes -> 'score')::integer + ?)::text) where knot_id = ? returning attributes->'score' as score");
	$sth->execute($score,session('user_id'));
	my $new_score = $sth->fetchrow();
	debug("NEWSCORE $new_score");
	session "score"=>$new_score;

};

ajax qr{/api/auth/} => sub {
	if (rate_limited('apiauth:'.client_ip(), 10, 60)) {
		debug "SECWARN rate-limited /api/auth/ from ".client_ip();
		status 429;
		return JSON::XS->new->utf8->encode({error=>'Too many attempts.'});
	}
	$login=param "login";
	$similarity=param "similarity";
	$hash_user=param "hash";
	# VOICEAUTH_SEED is meant to be a shared secret with the external voice-
	# auth microservice (mame.lesen.digital) -- it was never actually set in
	# config.yml, so config->{'VOICEAUTH_SEED'} was undef, stringifying to
	# '', meaning ANY hash computed against an empty secret would pass: a
	# full, unauthenticated "log in as anyone" bypass. Fail closed instead
	# of silently treating "not configured" as "secret is the empty string".
	my $seed = config->{'VOICEAUTH_SEED'};
	if (!$seed) {
		debug "SECWARN /api/auth/ called but VOICEAUTH_SEED is not configured -- refusing login for $login.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified.");
		return;
	}
	$hash_server=sha256_hex(encode("utf8",$login.$similarity.$seed));
	if ($hash_user eq $hash_server) {
		$login=~s/ /-/g;
		return login($login,1);
	} else {
		debug "SECWARN AUTH hash mismatch for $login.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified.");
	}
};

# /api/cast_token/: mints a short-lived signed token proving "a real
# Dancer2 session logged in as daniel-hromada asked for this, right now" --
# mainframe.tt's classroom-cast JS fetches this before connecting as
# teacher, and passes it to teacher.py's /ws relay, which verifies the
# signature + expiry instead of trusting a bare client-supplied role
# string (that used to let ANYONE connect as role=daniel-hromada and
# broadcast fake slide/audio state to every student).
get qr{/api/cast_token/?} => sub {
	header 'Content-Type' => 'application/json;charset=utf-8';
	if ((session('login') || '') ne 'daniel-hromada') {
		status 403;
		return JSON::XS->new->utf8->encode({error=>'Permission denied.'});
	}
	my $secret = config->{'CAST_TOKEN_SECRET'};
	if (!$secret) {
		status 500;
		return JSON::XS->new->utf8->encode({error=>'CAST_TOKEN_SECRET not configured.'});
	}
	my $expiry = time() + 300; # 5 minutes -- long enough to open the socket, short-lived if leaked
	my $sig = hmac_sha256_hex("daniel-hromada:$expiry", $secret);
	return JSON::XS->new->utf8->encode({token=>"$expiry:$sig"});
};

post qr{/api/ajax_update/(\d+)?/?} => sub {
	my $knot_content=decode_entities(param "knot_content");
	my $knot_name =param "knot_name";
	$knot_name=~s/^[\s+]//g;
	$knot_name=~s/[\s]$//g;
	debug("AJAXUPDATE $knot_id  $knot_name");
	my ($knot_id) = splat;
	if (!session('login')) {
		debug "SECWARN Non-logged in user called ajax_update $knot_id.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified."); 
	}

	if ($knot_content) {
		# knot_content renders raw (unescaped) on public pages -- see
		# sanitize_knot_content() in Core.pm for why this blocklist
		# exists and what it does/doesn't cover.
		$knot_content = sanitize_knot_content($knot_content);
		my $sth = database('knots')->prepare("update knots set knot_content=? where knot_id=?");
		$sth->execute($knot_content,$knot_id);
		$knot_content=~s/^[\s+]//g;
		$knot_content=~s/[\s]$//g;


	} elsif ($knot_name) {
		use HTML::Strip;
		my $hs = HTML::Strip->new();
		$knot_name = $hs->parse( $knot_name );
		$knot_name=~s/[^[:print:]]+//g;
		$knot_name=~s/^[\s+]//g;
		$knot_name=~s/[\s]$//g;

		my $sth = database('knots')->prepare("update knots set knot_name=? where knot_id=?");
		$sth->execute($knot_name,$knot_id);
	}
};	
post qr{/api/ajax_change_ord/(\d+)?/?} => sub {
	my $bound_id = param "bid";
	my $ord = param "ord";
	if (!session('login')) {
		debug "SECWARN Non-logged in user called ajax_change_ord $bound_id.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified."); 
	}
	debug "update bounds set ord=$ord where bound_id=$bound_id";
	my $h = database('knots')->prepare("update bounds set ord=? where bound_id=?");
	$h->execute($ord,$bound_id);
};

post qr{/api/update_attribute/(\d+)?/?} => sub {
	my ($knot_id) = splat;
	my $ord = param "ord";
	my $name = param "name";
	my $value = param "value";
	if (!session('login')) {
		debug "SECWARN Non-logged in user called update_attribute for $knot_id.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified."); 
	}
	debug "UPDATE ATTR $knot_id $name $value";
	my $h = database('knots')->prepare("update knots set attributes=attributes||hstore(?,?) where knot_id=?");
	$h->execute($name,$value,$knot_id);
};

post qr{/api/ajax_add_quality/(\d+)?/?} => sub {
	my $knot_id = param "knot_id";
	my $quality_id = param "quality_id";
	#my $ord = param "ord";
	if (!session('login')) {
		debug "SECWARN Non-logged in user called ajax_change_ord $bound_id.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified."); 
	}
	debug "ADDING QUALITY BOUND";
	addBound($knot_id,'has_quality',$quality_id);
	return "SUCCESS";
};

get '/api/knot_load/:id' => sub {
    header 'Access-Control-Allow-Origin' => '*';
    header 'Content-Type' => 'application/json;charset=utf-8';
 	my $sth=database('knots')->prepare("select knots.*,attributes->'lehrender' as lehrender, attributes->'raum' as raum, attributes->'tag' as tag,attributes->'uhrzeit' as uhrzeit,'' as attributes from knots where knot_id = ?");
	$sth->execute(route_parameters->get('id'));
        my $json = {};
        my $h = $sth->fetchrow_hashref();
	my $ret="{";
	for my $k (keys %{$h}) {
		my $val = $h->{$k};
                $val =~ s/"/\\"/g;
                $val =~ s/'/\\'/g;
                $val =~ s/\n/\\n/g;
                $val =~ s/\r/\\n/g;
		$ret .= "\"$k\":\"$val\",";
        }
	chop $ret;
	$ret .= "}";
	use Encode qw(encode);
	return encode('UTF-8', $ret,     Encode::FB_CROAK);
};


get '/api/childlist/:parent' => sub {
    header 'Access-Control-Allow-Origin' => '*';
    header 'Content-Type' => 'application/json; charset=utf-8';
        my $sth=database('knots')->prepare("select knots.*,attributes->'lehrender' as lehrender, attributes->'raum' as raum, attributes->'tag' as tag,attributes->'uhrzeit' as uhrzeit,'' as attributes from bounds left join knots on obj=knot_id where sub=? and predicate='is_parent'");
	$sth->execute(route_parameters->get('parent'));
	my $json = {};
	my %hash;
	while(my @titel = $sth->fetchrow_array()) {
		$hash{$titel[0]} = $titel[1];
	}
	my @keyz = sort { $hash{$a} cmp $hash{$b} } keys(%hash);
	my $ret = "[";
	for my $k (@keyz) {
		$hash{$k}=~s/"/\\"/g;
		$hash{$k}=~s/'/\\'/g;
		$hash{$k}=~s/\n/\\\\n/g;
		$ret .= "\"$k\",\"$hash{$k}\",";
	}
	chop $ret;
	$ret .="]";
	use Encode qw(encode);
	return encode('UTF-8', $ret,     Encode::FB_CROAK);
};


