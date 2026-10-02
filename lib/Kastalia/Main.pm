
package Kastalia::Main;
use utf8;
#use encoding::warnings;
use Dancer2;
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Ajax;

use Kastalia::User;

require Kastalia::Core;
require Kastalia::TT;
require Kastalia::SelectorQueries;
require Kastalia::API;

require BDLP::Main;

use Pg::hstore qw/hstore_encode hstore_decode/;
#JSON::XS (OO interface only -- JSON::XS->new->...) is already loaded via
#Kastalia::TT's `use JSON::XS;` above; a second `use JSON::XS;` here would
#just re-import encode_json/decode_json and trigger prototype warnings.
our $VERSION = '0.23';
#use constant APPURL => 'https://baumhaus.digital';
use constant APPURL => config->{'APPURL'};
#use constant DEFAULT_TEMPLATE => 'knot';
use constant DEFAULT_TEMPLATE => config->{'DEFAULT_TEMPLATE'};
#use constant KASTALIA_DIR => '/var/www/kastalia-kms/';
use constant KASTALIA_DIR => config->{'KASTALIA_DIR'};
use constant PUBLIC_DIR => KASTALIA_DIR.'public/';
use constant UTILS_DIR => KASTALIA_DIR.'utils/';

config->{'show_errors'}=0;

sub prepare_db {
	my $q="
	create or replace function build_family(p_parent int) returns setof jsonb as \$\$
	  select
	    case
	      when count(x) > 0 then jsonb_build_object('knot_id', obj, 'children', jsonb_agg(f.x), 'name',knots.knot_name,'content',knots.knot_content)
	      else jsonb_build_object('predicate', t.predicate, 'parent',sub,'terminal',obj,'name',knots.knot_name,'content',knots.knot_content)
	    end
	  from bounds as t left join knots on t.obj=knots.knot_id left join build_family(t.obj) as f(x) on true
	  where t.predicate='is_parent' and t.sub = p_parent or (p_parent is null and t.sub is null)
	  group by t.obj, t.sub,t.predicate,knots.knot_name,knots.knot_content;
	\$\$ language sql;
	";
	my $sth = database('knots')->prepare($q);
	$sth->execute();
}

#set log => 'debug';
prepare_db();

our $root_knot;

# Each domain in config.yml's host: section has a matching entry in
# domain_template: its own canonical, distinct way of viewing the knowledge
# graph. Requesting ".html" (or "!html") on any knot always renders that
# domain's canonical template, overriding whatever the knot's own `template`
# attribute says -- see the /view/ route, which is where every other route
# (numeric, meta-url, local-instance/referer) ends up forwarding to.
sub canonical_domain_template {
	return config->{'domain_template'}->{request->host} || DEFAULT_TEMPLATE;
}

hook after => sub {
	my $app = app();
 	my $ses = session();
	if (request->method eq 'GET') {
		session 'err' => '';
		session 'msg' => '';
	    	$ses && $ses->is_dirty && $app->session_engine->flush( session => $ses );
	}
};

get =>  qr{/portfolio/(\w+)} => sub {
	debug "PORTFOLIO";
        my ($artist) = splat;
        my $works = get_portfolio_by_artist($artist);
        template "portfolio", {layout=>'no','works'=>$works};
};

hook before => sub {
	#debug "REQPATH ".request->path;
	
	if (config->{'host'}->{request->host}) {
		$root_knot=config->{'host'}->{request->host};
	} else {
		$root_knot=config->{main_route};
	}
	#debug("ROOTKNOT is $root_knot");
	if (request->path eq '/') {
		session 'last_get_path' => $root_knot;
	}

	elsif (request->method eq 'GET' and request->path !~ '/login\/?/') {
		session 'last_get_path' => request->path; 
	}
	#debug "LASTGETPATH".(session 'last_get_path');
	#debug request->path;
	#debug request->host;
	#debug request->referer;
	#reset offset if not explicitely specified
	if (request->path !~ m{n$}) {
		session 'offset' => 0;
	}
	#debug 'REQREQ'.request->path;
	#if (!session('user')) {
	#	if (request->path=~m{/\d+}) {
	#}
	#	if (request->path !~ m{^/login}) {
	#		debug "DISP".request->path;
	#		session 'dispatch'=>request->path;
	#		forward '/login/';
	#	}
	#}
	#session 'user_id'=>1;
	#session 'user'=>'teacher';
	#session 'login'=>'teacher';
	#else {
	if (session('user')) {
		#debug "USERID".(session('user_id'));
		addZeitgeist(session('user_id'),request->path,request->method,{query_parameters->get_all});
	}
};

get '/auth' =>sub {
	debug("GET AUTH");
	rdrct("/".config->{'AUTH_KNOT'}.'/auth');
};

get '/ogg/*' => sub {
	my ($token) = splat;
	my $knot = get_last_knot_with_name($token);
	#debug $knot->{knot_id};
	my $ogg_file=get_ogg($knot->{knot_id});
	#debug $ogg_file;
	my $path="$ogg_file";
	#debug $path;
	send_file $path;
};

#this is to prevent leaking of personal informmation + creating mp3 variant if it does not exist
get qr{/audio/(\d+)\.(ogg|mp3)} => sub {
#get '/audio/*/' => sub {
	(my $id,my $type)=splat;
	my $ogg_file=get_attribute("ogg_url",$id);
	my $ogg_full=PUBLIC_DIR."data".$ogg_file;
	my $ogg_new=PUBLIC_DIR."data/audio/$id.ogg";
	if ($type eq 'ogg') {
		if (-f $ogg_full) {
			#debug("EXISTSFILW $ogg_file");
			send_file $ogg_file;
		} elsif (-f $ogg_new) {
			#debug("EXISTS sending $id");
			send_file "$id";
		} elsif ($ogg_file=~/^http/) {
			debug("downloadin $ogg_file to $ogg_new");
			`curl -k $ogg_file -o $ogg_new`;
			debug("HTTP sending $id.ogg");
		        send_file "$id";	
		}
	} elsif ($type eq "mp3") {
		my $mp3_file=$ogg_file;
		$mp3_file=~s/ogg$/mp3/;
		my $mp3_full=PUBLIC_DIR."data".$mp3_file;
		if (! -f PUBLIC_DIR."data".$mp3_file) {
			my $ogg_full=PUBLIC_DIR."data".$ogg_file;
			if ( -f $ogg_full) {
				`ffmpeg -i $ogg_full -acodec libmp3lame $mp3_full`;
				send_file $mp3_file;
			} 
			if ( -f $ogg_full) {
				`ffmpeg -i $ogg_full -acodec libmp3lame $mp3_full`;
				send_file $mp3_file;
			} 
		} else {
			send_file $mp3_file;
		}
	}
};

get qr{/portfolio/(\w+)} => sub {
	debug "PORTFOLIO";
        my ($artist) = splat;
        my $works = get_portfolio_by_artist($artist);
        template "portfolio", {layout=>'no','works'=>$works};
};

get '/image/*' => sub {
	my ($token) = splat;
	my $knot = get_first_knot_with_name($token);
	#debug $knot->{knot_id};
	#my $ogg_file=get_ogg($knot->{knot_id});
	#debug $ogg_file;
	my $path=$knot->{'img_url'};
	#debug Dumper($path);
	send_file $path;
};


post qr{/new_audio_knot/?} => sub {
	my $file = request->upload('audio_data');
	debug $file;
	my %h;
	return if !$file;
	my $content = params->{content};
	#my $age = params->{age};
	#my $gender = params->{gender};
	#my $motherlang = params->{motherlang};
	#my $licence = params->{licence};
	#my $zodiac = params->{zodiac};
	#debug "VOICEID $voice_id AGE $age GENDER $gender MOTHERLANG $motherlang NAME ".params->{knot_name};
	my $username=session('login');
	my $voice_id = params->{voice_id};
	$voice_id=$username if (!$voice_id || $voice_id=='undefined');
	my $basename = $file->basename;
	my $timestamps=params->{timestamps};
	my $text=params->{knot_name};
	my $followed_by=params->{followed_by};
	$text=~s/[\W]//g;

	#debug $timestamps;
	use Data::Dumper;
	#debug Dumper(params);
	$timestamps=~s/^(var words=)?\[//;
	chop $timestamps;
	$timestamps=~s/&nbsp;/ /g;
	$timestamps=~s/&/\&/g; # this seems to be very important security measure given that String::ShellQuote leaves ampersands intact ??!

	my $file_dest;
	die if $basename=~/\.\./;
	$content=~s/\W//g;
	my $parent_id=params->{knot_parent};
	my $wav=PUBLIC_DIR."/audio/";
	my $token=$voice_id;
	#this metadata is all we'll ever need to collect
	if (params->{age}) {
		$token="$token-".params->{age};
		session->write('age',params->{age});
	} if (params->{gender}) {
		$token="$token-".params->{gender};
		session->write('gender',params->{gender});
	} if (params->{motherlang}) {
		$token="$token-".params->{motherlang};
		session->write('motherlang',params->{motherlang});
	} if (params->{zodiac}) {
		$token="$token-".params->{zodiac};
		session->write('zodiac',params->{zodiac});
	} if (params->{consent}) {
		$token="$token-".params->{consent};
		session->write('consent',params->{consent});
	}
	$wav=$wav."$token-$parent_id-$basename.wav";
	
	if ($file->{'headers'}->{'Content-Type'}=='audio/webm') {
		`ffmpeg -i $file->{'tempname'} -vn -acodec pcm_s16le -ar 44100 -ac 2 $wav`;
		$file_dest=$wav;
	}
	else {
		$file->copy_to($file_dest = $wav);
	}
	debug($file_dest);
	#debug params->{consent}." $wav";

	my $knot_name = "Record of '".params->{knot_name}."' by $token";
	use Digest::MD5 qw(md5_hex);
	use Encode;
	$h{'ogg_url'}='/audio/'.md5_hex(Encode::encode_utf8($text)).'-'.uc($token).'-'.time().'.ogg';
	my $ogg_file=PUBLIC_DIR.$h{'ogg_url'};

	#sanitizing stuff which will be passed to shell (You never know...)
	use String::ShellQuote;
	my $timestamps_quoted=shell_quote $timestamps;
	$timestamps_quoted=~s/"/\\"/g;

	$ogg_file=shell_quote $ogg_file;
	$file_dest=shell_quote $file_dest;

	my $cmd = "opusenc --comment text=$timestamps_quoted $file_dest $ogg_file"; 
	#debug "ENC-CMD $cmd";
	`$cmd`;

	use URI::Encode qw(uri_decode);
	my $json=uri_decode($timestamps);

	#debug "PARAM".params->{update_existing};
	my $container_id=params->{container_id};
	#update existing knot
	if (params->{update_existing} && params->{container_id}) {
		#debug "UPDATING and redirecting to /view/$parent_id/knot";
		addAttribute($container_id,'autx_content',$json);
		addAttribute($container_id,'ogg_url',$h{'ogg_url'});
		addAttribute($container_id,'voice',$voice_id);
		#session 'msg' => "autx_content, ogg_url and voice attributes of $container_id successfully updated";
	}
	#insert new audio knot
	else {
		$h{'autx_content'}=$json;
		$h{'voice'}=$voice_id;
		$h{'age'}=params->{age};
		$h{'zodiac'}=params->{zodiac};
		$h{'motherlang'}=params->{motherlang};
		$h{'gender'}=params->{consent};
		$h{'consent'}=params->{consent};
		$h{'presentation_timeline'}=params->{presentation_timeline} if params->{presentation_timeline};
		$h{'presentation_id'}=params->{presentation_id} if params->{presentation_id};

		my $knot_id=addKnot($knot_name,$json,\%h);
		addBound($parent_id,'is_uttered_as',$knot_id);
		if ($container_id) {
			addBound($container_id,'contains',$knot_id) if $container_id;
			session 'container_id'=>$container_id;
		}
		#addition for presentation_recorder
		if (params->{presentation_id}) {
			addBound(params->{presentation_id},'has_session',$knot_id);
		}	
		#forward("/view/$followed_by/textrec") if $followed_by;
	}
	unlink $wav;
};

post qr{/attach_file/?} => sub {
	my $file = request->upload('data');
	my %h;
	debug "ATTACH FILE $file\n";
	return if !$file;
	my $knot_id = params->{knot_id};
	my $basename = $file->basename;
	my $attribute_name=params->{attribute_name};
	my $file_dest;
	die if $basename=~/\.\./;
	my $userbasename=session('login');
	if ($basename=~/\.tt$/) {
		#debug "PROBLEM  $userbasename $basename";
		$file_dest = KASTALIA_DIR."/views/$userbasename-$basename";
		$attribute_name="template";
		$basename=~s/\.tt$//;
        	my $sth = database('knots')->prepare("update knots set attributes = attributes || hstore(?,?)  where knot_id=?");
		$sth->execute($attribute_name,"$userbasename-$basename",$knot_id);
	} elsif ($attribute_name eq 'img_url' or $attribute_name eq 'lexeso_url') {
		$file_dest = PUBLIC_DIR."/data/img/$knot_id.$basename";
		debug "IMG_DEST $file_dest";
		#$h{$attribute_name}="/data/img/".$knot_id.$basename;
        	my $sth = database('knots')->prepare("update knots set attributes = attributes || hstore(?,'/data/img/' || ? || '.' || ?)  where knot_id=?");
		$sth->execute($attribute_name,$knot_id,$basename,$knot_id);
	} elsif ($attribute_name eq 'ogg_url' or $attribute_name eq 'speech_url') {
		$file_dest = PUBLIC_DIR."/data/audio/$knot_id.$basename";
		#$h{$attribute_name}="/data/img/".$knot_id.$basename;
        	my $sth = database('knots')->prepare("update knots set attributes = attributes || hstore(?,'/data/audio/' || ? || '.' || ?)  where knot_id=?");
		$sth->execute($attribute_name,$knot_id,$basename,$knot_id);
	} else { 
		$file_dest = PUBLIC_DIR."/data/$knot_id.$basename";
		$h{$attribute_name}="/data/$knot_id.$basename";
        	my $sth = database('knots')->prepare("update knots set attributes = attributes || hstore(?,'/data/' || ? || '.' || ?)  where knot_id=?");
		$sth->execute($attribute_name,$knot_id,$basename,$knot_id);
	}
	debug "COPYING TO $file_dest";
	$file->copy_to($file_dest);

	rdrct("/knot/$knot_id","$basename attached to attribute $attribute_name of the knot $knot_id.");
};


any ['get', 'post'] =>  qr{^/*$} => sub {
	debug 'MAIN '.$root_knot;
	#debug 'LASTGETPATH '.(session 'last_get_path');
	forward '/'.$root_knot, { method => 'GET' };
};

any ['get', 'post'] => qr{/logout/?} => sub {
	my $err = session('user').' logging out';
	my $sd=session->data;
	#my %h;
	#for my $k ($sd) {
	#		$h{$k}=$sd->{$k} if $k !~/^knot_/;	
	#}
	#use Data::Dumper;
	#debug(Dumper(\%h));
	debug($sd);
	my $sth=database('knots')->prepare('update knots set attributes=attributes || ? where knot_id=?');
	#$sth->execute(Pg::hstore::encode(session->data), session 'user_id');
	$sth->execute(Pg::hstore::encode($sd), session 'user_id');
	app->destroy_session;
	#debug $err;
	forward '/auth', {err=>$err},{ method => 'GET' };
};

post qr{/login/?} => sub {
	#debug "Logging in";
	use Net::LDAP;
	my $ldap = Net::LDAP->new(config->{ldap_host})  or  die "$@";
	my $l=params->{login};
	$l=~s/^ +//g;
	$l=~s/ +$//g;
	my $mesg = $ldap->bind("cn=$l,".config->{ldap_ou1}.",".config->{ldap_base},password => params->{pwd});
	if ($mesg->code!=0) {
		my $mesg = $ldap->bind("cn=$l,".config->{ldap_ou2}.",".config->{ldap_base},password => params->{pwd});
		if ($mesg->code!=0) {
			my $err="Authentication failed.";
			forward '/login', {err=>$err},{ method => 'GET' };
		}
	}
	login($l,0);
};

get qr{/login/?(\d+)?} => sub {
	my ($entrance_knot)=splat;
	forward '/bookmarks/' if session 'login';
	template 'login',{'err'=>params->{err}};
};
get qr{/self/?(\w+)?} => sub {
	my ($template)=splat;
	debug("FORWARDIN");
	forward '/'.session('user_id')."/$template" if session 'login';
};

#a dirty patch
#any ['get', 'post'] => qr{//knot/} => sub {
#	forward '/last';
#};

any ['get', 'post'] => qr{/last/?(n|p)?} => sub {
	my ($ajax_direction) = splat;
	my $offset = session 'offset';
	$offset = 0 if !$offset;
	$offset += 42 if $ajax_direction eq "n";
	my $knots=get_last($offset);
	#my $attributes = Pg::hstore::decode($knots->{attributes});
	#debug "LAST $offset";
	session 'offset' => $offset;
	my $user_id = session 'user_id';
	my $msg = session 'msg';
	my $err = session 'err';
	$ajax_direction ? template 'modules/last_knotlist',{layout=>'no','knots'=>$knots,  msg => session 'msg', err => session 'err', user_id => $user_id } : template 'last',{user_id => $user_id, layout=>'no','knots'=>$knots,  msg => $msg, err => $err };
};

any ['get', 'post'] => qr{/search/(.*)/?} => sub {
	my ($query) = splat;
	my $query=params->{query} if !$query;
	my $knots=get_search($query);
	my $user_id = session 'user_id';
	my $msg = session 'msg';
	my $err = session 'err';
	#debug $knots;
	template 'search', {user_id => $user_id, layout=>'no','knots'=>$knots,  msg => $msg, err => $err };
};

#was used for cafeteria display
#any ['get', 'post'] => qr{/display_admin/(\d+)} => sub {
#	my ($knot_id) = splat;
#	my $msg = session 'msg';
#	my $err = session 'err';
#	#my $relations=get_display_relations($knot_id);
#	my $priorities=get_bounds_by_obj_predicate($knot_id,'display_priority');
#	my $durations=get_bounds_by_obj_predicate($knot_id,'display_duration');
	#my $attributes = Pg::hstore::decode($knots->{attributes});
#	template 'display_admin',{layout=>'no','priorities'=>$priorities,msg=>$msg,err=>$err,'durations'=>$durations,'knot'=>get_knot($knot_id)};
#};

any ['get', 'post'] =>  qr{/view/(\d+)([/\-][-_\w]+)?} => sub {
	my ($knot_id,$template) = splat;
	session 'last_knot_id' => $knot_id;
	#debug "LAST CREATED KNOTS ARE ".session('last_created');
	my $knot = get_knot($knot_id);
	if ($template && $template=~/HMPL/) {
		debug("CACHIN");
		session 'knot' => $knot;
	} #else {
	#	debug("NOT CACHIN");
	#}
	my $attributes = Pg::hstore::decode($knot->{attributes});
	if (!session('user') && !$attributes->{'public'}) {
		#debug "AT".$attributes->{'public'};
		forward '/login/';
	}
	if (!$template) {
		$template = $attributes->{'template'};
		#debug "TEMPLATE is $template";
		$template = DEFAULT_TEMPLATE if (!$template);
	}
	my $objects = get_by_subject($knot_id);
	my $subjects = get_by_object($knot_id);
	my $zeitgeist = get_zeitgeist_by_knot($knot_id);
	my $msg = session 'msg';
	my $err = session 'err';
	use HTML::Entities;
	my $user_id = session 'user_id';
	my $login = session 'login';
	my $chtmle=$knot->{knot_content};
	encode_entities($chtmle);
	#$template=~s/(\/|\-)//g; #this will break many things
	$template=~s/(\/)//g;
	$template = canonical_domain_template() if $template eq 'html';
	#debug "TEMP $template";
	use Data::Dumper;
	my $parents = get_bounds_by_obj_predicate($knot_id);
	my $parent= $parents->[0];
	$knot->{'parent_name'}=$parent->{'knot_name'};
	$knot->{'parent_id'}=$parent->{'sub'};
	#debug 'REFREF'.(request->headers->referer);
	resetBound($knot_id,'obj','has_bookmark');
	my $session_data=\session->data;
	if ((!session 'user_id') && $template eq 'knot') {
		$err="Template $template disallowed for unauthenticated users.";
		$template=DEFAULT_TEMPLATE;
		debug($err);
	}
	my $canonical_domain=$knot->{'knot_name'};
	$canonical_domain=~s/\+\+.*//g;
	template $template, {layout=>'no','knot'=>$knot, 'objects' => $objects, 'subjects' => $subjects, 'a' => $attributes, 'zeitgeist'=> $zeitgeist, 'msg' => $msg, 'err' => $err, 'chtmle'=>$chtmle, 'user_id' => $user_id, 'login'=>$login, 'last_created' => session->read('last_created'), 'template_name'=>$template, 'request'=>request,'canonical_domain'=>$canonical_domain};
};

get qr{gen2/(\d+)/?$} => sub {
	my ($knot_id) = splat;
	my ($knot_id) = splat;
	my $knot = get_knot($knot_id);
	#line below can be removed after all templates will be updated to attached_attribute module (e.g. no a dictionary anymore)
	my $attributes = Pg::hstore::decode($knot->{attributes});
	my $objects = get_2generations($knot_id);
	my $subjects = get_by_object($knot_id);
	my $zeitgeist = get_zeitgeist_by_knot($knot_id);
	#debug Dumper($zeitgeist);
	my $msg = session 'msg';
	my $err = session 'err';
	use HTML::Entities;
	my $user_id = session 'user_id';
	my $chtmle=$knot->{knot_content};
	encode_entities($chtmle);
	#debug "WTF $chtmle\n";
	#debug Dumper($objects);
	template 'gen2', {layout=>'no','knot'=>$knot, 'objects' => $objects, 'subjects' => $subjects, 'a' => $attributes, 'zeitgeist'=> $zeitgeist, 'msg' => $msg, 'err' => $err, 'chtmle'=>$chtmle, 'user_id' => $user_id, 'bookmarks' => session 'bookmarks' };
};


get qr{knot/(\d+)/?$} => sub {
	my ($knot_id) = splat;
	#debug "FORWARDINK";
	forward("/view/$knot_id/knot");
};

get qr{/name/(.+?)/(\w+)?} => sub {
	my ($knot_name,$template) = splat;
	#debug "KNOT_NAME $knot_name";
	#in kastalia URIs we substitute blankspaces into + symbols
	$knot_name=~s/\+/ /g;
	my $knot = get_last_knot_with_name($knot_name);
	my $knot_id=$knot->{knot_id};
	my $attributes = Pg::hstore::decode($knot->{attributes});
	my $objects = get_by_subject($knot_id);
	my $subjects = get_by_object($knot_id);
	my $parents = get_bounds_by_obj_predicate($knot_id);
	my $parent= $parents->[0];
	$knot->{'parent_name'}=$parent->{'knot_name'};
	$knot->{'parent_id'}=$parent->{'sub'};
my $zeitgeist = get_zeitgeist_by_knot($knot_id);
	#debug Dumper($zeitgeist);
	my $msg = session 'msg';
	my $err = session 'err';
	use HTML::Entities;
	my $user_id = session 'user_id';
	my $chtmle=$knot->{knot_content};
	encode_entities($chtmle);
	#debug "WTF $chtmle\n";
	if (!$template) {
		$template = $attributes->{'template'};
		#debug "TEMPLATE is $template";
		$template = DEFAULT_TEMPLATE if (!$template);
	}

	template $template, {layout=>'no','knot'=>$knot, 'objects' => $objects, 'subjects' => $subjects, 'a' => $attributes, 'zeitgeist'=> $zeitgeist, 'msg' => $msg, 'err' => $err, 'chtmle'=>$chtmle, 'user_id' => $user_id, 'bookmarks' => session 'bookmarks' };
};

#was used at typ-udk.de and uses the pre-TT.pm approach, can be removed in some future commit
#get qr{/typ/(\d+)?/?} => sub {
#	my ($knot_id) = splat;
#	my $knot = get_knot($knot_id);
#	my $gen2 = get_grandchildren_sample($knot_id);
#	my $children = get_children($knot_id);
#        my $attr = Pg::hstore::decode($knot->{attributes});
#	debug $knot_id;
#	use Data::Dumper;
#	if ($knot_id eq 1003) {
#		my @a=qw(Schriftname Gestaltung Jahr);
#		my $matrix=get_child_attribute_matrix(895,@a);
#		debug $matrix->[1];
#		template 'typ', {layout=>'no','knot'=>$knot,'mtrx'=>$matrix};
#	}
#	else {
#		template 'typ', {layout=>'no','gen2' => $gen2,'children'=>$children,'knot'=>$knot,'attr'=>$attr};
#	}
#};

#medienhaus cafeteria display related
#get qr{/display/(\d+)?/?} => sub {
#        my ($knot_id) = splat;
#        my $knot = get_display($knot_id);
#        my $attributes = Pg::hstore::decode($knot->{attributes});
#        template 'display', {layout=>'no','knot'=>$knot, 'a' => $attributes };
#};

get qr{/zeitgeist/(\d+)?/?} => sub {
	my ($timestamp) = splat;
	my $zeitgeist = get_zeitgeist($timestamp);
	my $user_id = session 'user_id';
	template 'zeitgeist', {layout=>'no','zeitgeist'=>$zeitgeist,'user_id'=>$user_id};
};

get qr{/bounds/(\d+)?/?} => sub {
	my ($timestamp) = splat;
	my $user_id = session 'user_id';
	my $bounds = get_bounds($timestamp);
	template 'bounds', {layout=>'no','bounds'=> $bounds, 'user_id'=>$user_id};
};

any ['get', 'post'] =>  qr{/bookmarks/?(\d+)?/?} => sub {
	my ($user_id) = splat;
	$user_id = session('user_id') if !$user_id;
	my $bookmarks = get_bookmarks($user_id);
	template 'bounds', {layout=>'no','bounds'=> $bookmarks, 'bookmarks'=>1,'user_id'=>$user_id};
};


#post qr{/change_ord/(\d+)?/?} => sub {
#	my $parent_id = param "rid";
#	debug "CHANGE_ORD $parent_id";
#	my $bound_id = param "bid";
#	my $ord = param "ord";
#	my $h = database('knots')->prepare("update bounds set ord=? where bound_id=?");
#	$h->execute($ord,$bound_id);
#        fwd($parent_id,"Bound's strength updated.","display_admin"); 
#};


#change_priority will become obsolete after change_ord is fully working
#post qr{/change_priority/(\d+)?/?} => sub {
#	my ($parent_id) = splat;
#	my $child_id = param "child_id";
#	my $priority = param "priority";
#	my $studiengang = param "studiengang";
#	my $h = database('knots')->prepare("update bounds set ord=? where sub=? and obj=?");
#	$h->execute($priority,$parent_id,$child_id);
#       fwd($parent_id,"Priority updated."); 
#};

post qr{/destroy_bound/(\d+)?/?} => sub {
	#my ($parent_id) = splat;
	my $bid = param "bid";
	debug("destroyin $bid");
	if (!session('login')) {
		#debug "SECWARN Non-logged in user called destroy_bound $bid.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified."); 
	}
	my $h = database('knots')->prepare("delete from bounds where bound_id=? and (predicate != 'created_by' or predicate IS NULL)");
	#debug "delete from bounds where bound_id=$bid and predicate!='created_by'";
	$h->execute($bid);
        rdrct((session 'last_get_path'),"Bound destroyed."); 
};


post qr{/inject/(\d+)?/?} => sub {
	my ($parent_id) = splat;
	my $child_id = param "child_id";
	if (!session('login')) {
		#debug "SECWARN Non-logged in user posted inject $child_id into $parent_id.";
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified."); 
	}
	#my $studiengang = param "studiengang";
	my $h = database('knots')->prepare("insert into bounds (sub,obj,predicate,bound_creator) values (?,?,?,?) ON CONFLICT on constraint bounds_sub_obj_predicate_ord_key DO NOTHING");
	$h->execute($parent_id,$child_id,'is_parent',session('user_id'));
	rdrct((session 'last_get_path'),"Knot $child_id succesfully injected into $parent_id.");
};

sub fwd {
	(my $id, my $msg, my $template) = @_;
	if (!$template) {
		if ((session 'studiengang') eq 'vk') {
			forward "/vk_admin/$id", {msg=>"$msg"},{ method => 'GET' };
		} elsif ((session 'studiengang') eq 'kum') {
			forward "/kum_admin/$id", {msg=>"$msg"},{ method => 'GET' };
		} 
		else {
			forward "/knot/$id", {msg=>"$msg"},{ method => 'GET' };
		}
	}
	else {
		rdrct("/$template/$id",$msg,"");
	}
}

sub rdrct {
	(my $url, my $msg, my $err) = @_;
	session 'msg' => $msg if ($msg);
	session 'err' => $err if ($err);
	#debug "REDIRECTION $url $msg $err";
	#redirect APPURL.$url;
	redirect $url;
}

#post qr {/update_annotation/} => sub {
#        my $knot_id = param "knot_id";
#	my $annotation = param "annotation";
#}

post qr {/create_attribute/?} => sub {
        my $knot_id = param "knot_id";
        my $a_name=param "name";
	my $a_value;
	if ($a_name eq 'ocr' && param "annotation") {
		$a_value=param "annotation";
		$a_value=~s/^\[//;
		$a_value=~s/\]$//;
		$a_name="annotation"
	}
        else {
		$a_value=param "value";
	}
	if ($a_name eq 'score') {
		debug "UPDATE SCORE VIOLATION BY ".session('login');
		rdrct((session 'last_get_path'),"Permission denied. Guild of Teachers has been notified."); 
	}

        my $sth2 = database('knots')->prepare("update knots set attributes=attributes || ? where knot_id=?");
        $sth2->execute(hstore_encode({$a_name=>$a_value}),$knot_id);
	addAttribute($knot_id,$a_name,$a_value);
        if (param 'apply_children') {
		my @children = database('knots')->quick_select('bounds', { sub => $knot_id, predicate=>param "predicate" });
		for my $child (@children) {
			#debug $child;
			#my $sth2 = database('knots')->prepare("update knots set attributes=attributes || ? where knot_id=?");
			#$sth2->execute(hstore_encode({$a_name=>$a_value}),$child->{'obj'});
			addAttribute($child->{'obj'},$a_name,$a_value);
                }
		my @children = database('knots')->quick_select('bounds', { sub => $knot_id, predicate=>'is_parent' });
		for my $child (@children) {
			debug $child;
                        my $sth2 = database('knots')->prepare("update knots set attributes=attributes || ? where knot_id=?");
                        $sth2->execute(hstore_encode({$a_name=>$a_value}),$child->{'obj'});
                }

        }
	#this could be done in a much more elegant manner (e.g. use get_2generations from SelectorQueries.pm) but 
	if (param 'apply_grandchildren') {
		my @children = database('knots')->quick_select('bounds', { sub => $knot_id, predicate=>param "predicate" });
		my $children=get_2generations($knot_id);
		for my $child (@$children) {
			#debug $child;
                        #my $sth2 = database('knots')->prepare("update knots set attributes=attributes || ? where knot_id=?");
			#$sth2->execute(hstore_encode({$a_name=>$a_value}),$child->{'id'});
			addAttribute($child->{'id'},$a_name,$a_value);
			#my $sth2 = database('knots')->prepare("update knots set attributes=attributes || ? where knot_id=?");
			#$child->{'obj'});
			#my @grandchildren = database('knots')->quick_select('bounds', { sub => $child->{'obj'}, predicate=>'is_parent' });
                }
        }

        rdrct("/knot/$knot_id","$a_name attributed.");
};

post qr {/update_content/?} => sub {
	#debug "!!!!!!!!!!!!!!!!!!!ENTERING UPDC";
	my $knot_id = param "knot_id";
	my $knot_content=param "knot_content";
	my $sth2 = database('knots')->prepare("update knots set knot_content = ? where knot_id=?");
	#debug "update knots set knot_content = '$knot_content' where knot_id='$knot_id'";
	$sth2->execute($knot_content,$knot_id);
	rdrct("/knot/$knot_id","Knot content updated.");
};	


post qr {/bookmark/?} => sub {
	my $knot_id = param "knot_id";
	my $user_id = session('user_id');
	addBound($user_id,'has_bookmark',$knot_id);
	rdrct("/knot/$knot_id","Knot $knot_id bookmarked by $user_id.");
};

post qr {/ocr_img/?} => sub {
	my $knot_id = param "knot_id";
	my $user_id = session('user_id');
	my $knot = get_knot($knot_id);
	my $img_file = PUBLIC_DIR.$knot->{'img_url'};
	debug $img_file;

	my $img_desc=`identify $img_file`;
	$img_desc=~/ (\d+)x(\d+) /;
	my $img_width=$1;
	my $img_height=$2;
	print "$img_width $img_height";

	my $tsv=`tesseract $img_file stdout -l deu tsv`;
	use Text::CSV qw(csv);
	debug $tsv;
	my $aoh = csv (in => \$tsv, headers => "auto",  sep_char=> "\t", escape_char => "\\" );
	my $line_count=0;
	my $json="";
	my $fulltext="";
	for my $row (@$aoh) {
		my $text=$row->{'text'};
		if ($text=~/[^\s]/) {
			$json = $json . '{"id":"w_'.$knot_id.'_'.$line_count.'","ocr":"'.$text.'","left":'.$row->{left}/$img_width.',"top":'.$row->{top}/$img_height.',"width":'.$row->{'width'}/$img_width.',"height":'.$row->{'height'}/$img_height.'},';
		}
		$line_count += 1;
		$fulltext=$fulltext." ".$text;
	}
	#debug $json;
	addAttribute($knot_id,'ocr',$json);
	rdrct("/knot/$knot_id","Img associated to $knot_id OCRed. Check its OCR attribute.");
};


post qr {/speech_segment/?} => sub {
	my $knot_id = param "knot_id";
	my $user_id = session('user_id');
	my $knot = get_knot($knot_id);
	use String::ShellQuote;
	my $speech_file = shell_quote PUBLIC_DIR.$knot->{'speech_url'};
	my $cmd=UTILS_DIR."/segment_audio.py -i $speech_file --host ".config->{mikroserver_host}." -v ".session('login');
	$cmd.=" -s ".$knot->{'scorer'} if $knot->{'scorer'};
	$cmd.=" -l ".$knot->{'lang'} if $knot->{'lang'};
	debug($cmd);
	my @transcriptions=`$cmd`;
	my $segment_id=0;
	for my $transcription (@transcriptions) {
		my %h;
		my $ogg_file="$speech_file-$segment_id.ogg";
		debug $ogg_file;
		`opusenc $speech_file-$segment_id.wav $ogg_file`;
		$h{'transcription_candidates'}=$transcription;
		$ogg_file=~s/${\PUBLIC_DIR}//;
		debug $ogg_file;
		$h{'ogg_url'}=$ogg_file;
		my $segment_knot_id=addKnot($knot->{knot_name}."++$segment_id","",\%h);
		addBound($knot_id,'contains',$segment_knot_id);
		$segment_id++;
	}
	#return(@transcriptions);
	rdrct("/knot/$knot_id","$speech_file split into ".scalar(@transcriptions));
};

post qr {/split/?} => sub {
	#debug 'SPLITSPLIT';
	my $knot_id = param "knot_id";
	my $user_id = session('user_id');
	my $knot = get_knot($knot_id);
	my $followed_by;
	#my @new_contents=reverse(split(/:::/,$knot->{'knot_content'}));
	my @new_contents=(split(/:::/,$knot->{'knot_content'}));
	my $index=scalar(@new_contents);
	for my $new_content (@new_contents) {
		my %h;
		#$h{'followed_by'}=$followed_by if $followed_by;
		#$followed_by=addKnot($knot->{'knot_name'}."::$index",$new_content,\%h);
		#$followed_by=addKnot("[$new_content]",$new_content,\%h);
		$followed_by=addKnot($knot->{knot_name}."/$new_content",$new_content,\%h);
		#addBound($knot_id,'is_parent',$followed_by,1000-(10*$index));
		addBound($knot_id,'is_parent',$followed_by,1);
		$index--;
	}
	rdrct("/knot/$knot_id","Knot $knot_id split into chain of ".scalar(@new_contents)." knots.");
};

get qr {^/(\d+)([/.]\w+)?/?$} => sub {
	(my $knot_id, my $template) = splat;
	if ($template) {
		$template=~s/^[\/.]//;
		forward("/view/$knot_id/$template");
	} else {
		forward("/view/$knot_id");
	}

};

get qr {^/wiki/(.*)$} => sub {
	(my $article)=splat;
	debug "URL $article";
	my $url="de.wikipedia.org/wiki/$article" if $article!~/wikipedia\.org/;
	`wget -P ./public/wiki/ -rEDpkH -l2 --span-hosts --domains=de.wikipedia.org,en.wikipedia.org,upload.wikimedia.org,wikimedia.org '$url'`;
	open(IN, "< ./public/wiki/$url.html") or die $!;
	open(OUT, "> ./public/wiki/$url") or die $!;
	while(<IN>) {
    		$_ =~ s/rel="stylesheet" href="\/w\/load.php\?.*"/rel="stylesheet" href="\/w\/load.css"/g;
    		$_ =~ s/src="\/w\/load.php\?.*"/rel="stylesheet" href="\/w\/load.js"/g;
		$_ =~ s/src="\/\//src="\/w\//g;
		$_ =~ s/\/\/upload/\/w\/upload/g;
		print OUT $_;
	}
	
	close(IN);
	close(OUT);
	my %attributes;
	$attributes{'wiki_url'}="https://$url";
	$attributes{'reveal_title_iframe_url'}="/wiki/$article";
	#my $knot_id=addKnot("plant::$article","",\%attributes);
	#addBound(45,"contains",$knot_id);
	#addBound(45,"is_parent",$knot_id);
	#addBound(210,"contains",$knot_id);
	#debug "redirect to https://1.teacher.solar:777/wiki/$url";
	#redirect "https://1.teacher.solar:777/wiki/$article";
};

#get qr {/(\d+)$} => sub {
#	(my $knot_id) = splat;
#	debug "redirectin to KNOT";
#	forward("/knot/$knot_id");
#};

#germans love the uppercase-lowercase distinction, so why not use it for this megacool feature?
#get qr {/([0-9ä\p{L} ]+)(/0-9\p{L}+)?/?$} => sub {

#meta-urls
get qr {/_/(.+?)([!.][\:/0-9\w_]+)?/?$} => sub {
	(my $knot_name,my $template) = splat;
	$template=~s/^[!.]// if $template;
	$knot_name=~s/\//++/g;
	debug($knot_name." ".$template);
	my $knot=get_first_knot_with_name($knot_name);
	if (!$knot->{"knot_id"}) {
		forward($root_knot);
	}	
	if (!session('user') && !$knot->{'public'}) {
		session 'dispatch'=>request->path;
		forward '/login/';
	}
	if (!$template) {
		debug "no template";
		if ($knot->{'template'}) {
			debug "no knot template";
			$template=$knot->{'template'}
		}
		else {
			$template=DEFAULT_TEMPLATE;
		}
	}
	forward("/".$knot->{"knot_id"}."/$template");
};

#local instance urls -- domain/knot_name.template or domain/referer.template
#(also accepts the older domain/knot_name!template form)
get qr {/(.+?)([!.][\:/0-9\w_]+)?/?$} => sub {
	(my $knot_name,my $template) = splat;
	$template=~s/^[!.]// if $template;
	$knot_name=~s/\+\+/\//g; #backwards compatibility
	my $knot=get_first_knot_with_name($knot_name);
	if (!$knot->{"knot_id"}) {
		$knot=get_first_knot_with_referer($knot_name);
	}
	#use Data::Dumper;
	#debug Dumper($knot);
	$template=$knot->{'template'} if !$template;
	$template=DEFAULT_TEMPLATE if !$template;
	if (!$knot->{"knot_id"}) {
		forward($root_knot);
	}	
	if (!session('user') && !$knot->{'public'}) {
		session 'dispatch'=>request->path;
		forward '/login/';
	}
	debug("/".$knot->{"knot_id"}."/$template");
	forward("/".$knot->{"knot_id"}."/$template");
};

post qr {/propagate/} => sub {
	my $knot_id=param "kid";
	my $source=param "source";
	my $target=param "target";
	my $replicate=param "replicate";
	debug "entering PROPAGATE $knot_id S $source T $target R $replicate";
	#database('knots')->trace(2);
	my @source = database('knots')->quick_select('bounds', { obj => $knot_id, predicate=>$source });
	print("WTF");
	print(@source);
	for my $origin (@source) {
		my $origin_id=$origin->{'sub'};
		debug "propagating for $origin_id";
		#this thing needs to be updated to take into account diverse sub / obj role configurations
		my @target = database('knots')->quick_select('bounds', { sub => $origin_id, predicate=>$target });
		my @replicate = database('knots')->quick_select('bounds', { obj => $origin_id, predicate=>$replicate });
		for my $sub (@replicate) {
			for my $obj (@target) {
				if (!database('knots')->quick_select('bounds', { sub => $sub->{'sub'}, predicate=>$replicate, obj=>$obj->{'obj'} })) {
					addBound($sub->{'sub'},$replicate,$obj->{'obj'},1);
				}
			}
		}
	}
	forward("/$knot_id");

};

post qr {/create_bound/?} => sub {
	my $origin_id = param "origin_id";
	my $target_id = param "target_id";
	my $target_name = param "target_name";
	my $predicate = param "predicate";
	my $ord = param "strength";
	my $flip_roles = param "flip_roles";
	#my $sub;
	#my $obj;
	#the role-based approach is too complicated for an ordinary human
	#if ($role eq 'sub') {
	#	$sub=$target_id;
	#	$obj=$origin_id;
	#	debug "SA $sub $obj $role $predicate $ord";
	#} 
	#the role-based approach is too complicated for an ordinary human
	#else {
	#	$sub=$origin_id;
	#	$obj=$target_id;
		#debug "OA $sub $obj $role $predicate $ord";
	#}
	rdrct((session 'last_get_path'),"Invalid (empty?) predicate.") if (!$predicate);
	#
	my ($msg,$err)="";
	#expand the list
	if ($flip_roles) {
		if ($target_name) {
			my $knot=get_first_knot_with_name($target_name);
			my $knot_id=$knot->{'knot_id'};
			if ($knot_id) {
				addBound($knot_id,$predicate,$origin_id,$ord);
			}
			else {
				$err="Knot with name $target_name does not exist.";
			}
		}
		elsif ($target_id=~/,/) {
			for my $sub (split(',',$target_id)) {
				addBound($sub,$predicate,$origin_id,$ord);
			}
		}
		else {
			my @targets=split('-',$target_id);
			addBound($targets[0],$predicate,$origin_id,$ord);
			if ($targets[1]) {
				for my $sub ($targets[0]..$targets[1]) {
					addBound($sub,$predicate,$origin_id,$ord);
				}
			}
		}
	} else {
		if ($target_name) {
			my $knot=get_first_knot_with_name($target_name);
			my $knot_id=$knot->{'knot_id'};
			if ($knot_id) {
				addBound($origin_id,$predicate,$knot_id,$ord);
			} else {
				$err="Knot with name $target_name does not exist.";
			}
		}
		elsif ($target_id=~/,/) {
			for my $obj (split(',',$target_id)) {
				addBound($origin_id,$predicate,$obj,$ord);
			}
		}
		else {
			my @targets=split('-',$target_id);
			addBound($origin_id,$predicate,$targets[0],$ord);

			if ($targets[1]) {
				for my $obj ($targets[0]..$targets[1]) {
					addBound($origin_id,$predicate,$obj,$ord);
				}
			}
		}
	}
	session->write('last_predicate',$predicate);
	rdrct((session 'last_get_path'),"Bound created.");
};	
post qr {/insert/?} => sub {
	my $parent_id = param "parent_id";
	my $knot_name=param "name";
	my $predicate=param "predicate";
	rdrct((session 'last_get_path'),'','Leerer Titel nicht erlaubt.') if (!$knot_name);
	my $knot_content=param "content";
	$knot_content=~s/\n/<br>/g;
	my $file = request->upload('data');
	#my $knot_id=addKnot($knot_name,$knot_content,{'creator'=>session('login')});

	my $knot_id=addKnot($knot_name,$knot_content);

	#my $last_created = session('last_created');
	#push($last_created,"$knot_name#$knot_id");
	session->write('last_created_name',$knot_name);
	session->write('container_id',$knot_id);

	addBound($parent_id,$predicate,$knot_id);
	#addBound((session('user_id')),'created_by',$knot_id);
	#debug "REINFORCING RELATION";
	strenghtenBound($parent_id,'obj','has_bookmark');
	session->write('last_predicate',$predicate);
	rdrct("/knot/$knot_id","$knot_name successfully inserted.");
};

# /knotize/ turns a JSON document -- typically a presentation an AI system
# drafted -- into a set of knots+bounds, so it can be displayed right away
# through the existing baumhaus/player (reveal.js) templates, exactly as if
# every slide had been added by hand through /insert/.
#
# Two accepted JSON shapes (see Kastalia::Core::knotize_node/knotize_list):
#   {}  an object -> a new root knot is created for it (optionally bound
#       under :parent_id / ?parent_id=), and its "slides"/"children" array
#       (if any) is knotized underneath, recursively.
#         {"name":"My Talk","attributes":{"author":"..."},
#          "slides":[{"name":"Slide 1","content":"<p>...</p>"}, ...]}
#   []  a bare array -> no root knot is created; every element is knotized
#       directly as a child of the required parent_id.
#
# The JSON can arrive either as a POST field named "json" (e.g. a pasted-in
# textarea, or a plain curl -d 'json=...' form post) or as a raw
# application/json request body (the natural shape for an AI system/script
# calling this endpoint directly).
#
# Responds with a redirect (matching every other mutating route in this
# file) for normal browser/form submissions, or with a small JSON summary
# for anything that looks like a script/ajax caller.
post qr{/knotize/(\d+)?/?} => sub {
	my ($parent_id) = splat;
	$parent_id ||= param "parent_id";

	my $ctype = request->header('Content-Type') || '';
	my $accept = request->header('Accept') || '';
	my $wants_json = $ctype =~ m{application/json} || $accept =~ m{application/json} || request->header('X-Requested-With');

	if (!session('login')) {
		debug "SECWARN Non-logged in user called knotize.";
		if ($wants_json) {
			status 403;
			header 'Content-Type' => 'application/json;charset=utf-8';
			return JSON::XS->new->encode({success=>\0,error=>'Permission denied.'});
		}
		rdrct((session 'last_get_path'),"Permission denied. Administrator guild has been notified.");
	}

	#A real file upload (multipart/form-data, field "json" or "json_file")
	#takes priority -- this is what makes "knotize this .json file" work,
	#either from the paste-box form's file input or from
	#`curl -F json_file=@presentation.json`. Its content comes back as raw
	#bytes (Upload->content defaults to the ':raw' layer), so it needs
	#JSON::XS's own ->utf8 decoding rather than relying on Dancer2's
	#charset magic, which only applies to already-decoded param/body text.
	my $upload = request->upload('json_file') || request->upload('json');
	my $raw;
	my $data;
	if ($upload) {
		$raw = $upload->content;
		$data = eval { JSON::XS->new->utf8->decode($raw) };
	} else {
		$raw = param('json');
		$raw = request->body if (!defined($raw) || $raw eq '');
		$data = eval { JSON::XS->new->decode($raw) };
	}
	if ($@ || !defined($data)) {
		#surface JSON::XS's own message (it names the byte offset and a
		#snippet of context) instead of a bare "invalid JSON" -- that's
		#normally the only clue we get, since production logs at 'error'
		#level and this eval's $@ never reaches them otherwise.
		my $parse_err = "$@" || 'empty or unparsable body';
		$parse_err =~ s/[\r\n]+/ /g;
		$parse_err =~ s/[<>]//g;
		$parse_err = substr($parse_err,0,300);
		debug "KNOTIZE json parse error (raw length ".length($raw//'')."): $parse_err";
		if ($wants_json) {
			status 400;
			header 'Content-Type' => 'application/json;charset=utf-8';
			return JSON::XS->new->encode({success=>\0,error=>"Invalid JSON: $parse_err"});
		}
		rdrct((session 'last_get_path'),'',"Knotize failed: invalid JSON: $parse_err");
	}

	my ($root_id,$created);
	if (ref($data) eq 'ARRAY') {
		if (!$parent_id) {
			if ($wants_json) {
				status 400;
				header 'Content-Type' => 'application/json;charset=utf-8';
				return JSON::XS->new->encode({success=>\0,error=>'parent_id required when knotizing a bare JSON array of slides.'});
			}
			rdrct((session 'last_get_path'),'',"Knotize failed: parent_id required for a slide array.");
		}
		$created = knotize_list($data,$parent_id);
		$root_id = $parent_id;
	} elsif (ref($data) eq 'HASH') {
		$root_id = knotize_node($data,$parent_id,undef);
		$created = [$root_id];
	} else {
		if ($wants_json) {
			status 400;
			header 'Content-Type' => 'application/json;charset=utf-8';
			return JSON::XS->new->encode({success=>\0,error=>'Top-level JSON must be an object or an array.'});
		}
		rdrct((session 'last_get_path'),'',"Knotize failed: JSON must be an object or an array.");
	}

	addZeitgeist(session('user_id'),'knotize','post',{parent_id=>$parent_id,root_id=>$root_id,count=>scalar(@$created)});

	if ($wants_json) {
		header 'Content-Type' => 'application/json;charset=utf-8';
		return JSON::XS->new->canonical->encode({success=>\1,root_id=>$root_id+0,created=>[map {$_+0} @$created],count=>scalar(@$created)});
	}
	rdrct("/knot/$root_id",scalar(@$created)." knot(s) successfully knotized.");
};
true;
