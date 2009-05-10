#!/usr/bin/perl
# @author Bruno Ethvignot <bruno at tlk.biz>
# @created 2005-05-03
# @date 2009-05-01
#
# copyright (c) 2008-2009 TLK Games all rights reserved
# $Id$
#
# Tootella-like is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Tootella-like is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.
use strict;
use Config::General;
use Data::Dumper;
use diagnostics;
use Fcntl qw(:DEFAULT :flock);
use File::stat;
use FindBin qw($Bin $Script);
use Getopt::Long;
use HTML::Entities;
use IO::File;
use LWP::UserAgent;
use POSIX ":sys_wait_h";
use Sys::Syslog;
use Template;
use Term::ANSIColor;
use XML::RSS;

my $pid_handle;
my $configFileName = 'tootella-like.conf';
my $documentRoot   = './bubux/';
my $mainFolder     = 'pages/';
my $splitFolder    = 'pages/split/';
## -l option: Use local RSS files is forced l
my $useLocalRSSFiles;
## verbose mode (option -v)
my $isVerbose;
## generates only the "tout.html" page (-t option)
my $generateTheAllPage;
## specific page(s) are requested (-p option)
my $specificPageRequest;
## list of specific pages to generate (option -p)
my %specificPagesRequested;
my $warnError;
my $userAgent;
my $feedPages_ref;
my $RSSDirname;
my @menusList;
my @menusListSplit;
my $rh_zite;
my $startTime = time;
my $pidfile;
my $http_ref;
my $sysLog_ref;
my $logFilename;

eval {
  init();
  run();
};
if ($@) {
    sayError($@);
    sayError("(!) tootella-like.pl failed!");
    die $@;
}
sayInfo( "(*) Time of execution: " . ( time - $startTime ) . " seconds" );

## @method void END()
sub END {
    if ( defined $sysLog_ref ) {
      Sys::Syslog::closelog();
    }
}

## @method void run()
# @brief main loop / create all HTML pages
sub run {

    my $template = Template->new(
        {   EVAL_PERL    => 0,
            INCLUDE_PATH => $Bin . '/templates'
        }
    );

    # hash used for template variables
    my $templateVars_ref = {};
    ( $templateVars_ref->{'date'}, $templateVars_ref->{'datetime'} )
        = getDate();

    # hachage des sites deja traites
    my %h_website2items = ();    #evite de traiter 2 fois le meme fil
    my %h_website2error = ();

    #list of sites for the two "tout.html" pages
    my @a_Asites         = ();                  #1 column : websites list
    my @a_AleftWebsites  = ();                  #2 columns : websites at left
    my @a_ArightWebsites = ();                  #2 columns : websites at right
    my $ra_AsplitSites   = \@a_AleftWebsites;
    # avoids having 2 times the websame site
    my %h_pageToutFlags = (); 

    # page counter from 1 to n (n = 9 currently)
    my $pageCounter = 0;

    # loop of each HTML page
    foreach my $htmlPage_ref (@$feedPages_ref) {
        $pageCounter++;
        next
            if defined($specificPageRequest)
                and !exists( $specificPagesRequested{$pageCounter} );
        my $s_page = $htmlPage_ref->{page};
        sayInfo("run() generate page number: $s_page");
        my $ra_sites       = $htmlPage_ref->{sites};
        my @a_sites        = ();               #one column : websites list
        my @a_leftWebsites = ();               #two columns : websites at left
        my @a_rightWebsites = ();    #tow columns : websites at right
        my $ra_splitSites = \@a_leftWebsites;

        # loop oh each website
        foreach my $rh_site (@$ra_sites) {
            my $titleOfFeed = $rh_site->{'titre'};
            sayDebug("run() process '$titleOfFeed' ");
            my $s_lang;
            if ( exists( $rh_site->{'lang'} ) ) {
                $s_lang = $rh_site->{'lang'};
            }
            else {
                $s_lang = 'fr';
                sayError("run() no language code found");
            }
            if ( !length( $rh_site->{'rss'} ) ) {
                $h_website2error{$titleOfFeed} = 1;
                next;
            }
            $rh_zite = {};
            my $s_rss = $rh_site->{'rss'};

            # genere le nom du fichier local RSS
            my $s_fichierd = $titleOfFeed;
            $s_fichierd =~ s/(&eacute;|&egrave;|&ecirc;)/e/g;
            $s_fichierd =~ s/(&aacute;|&agrave;|&acirc;)/a/g;
            $s_fichierd = lc($s_fichierd);
            $s_fichierd =~ s/\s+/-/g;
            $s_fichierd =~ s/\-+/-/g;
            my $rssItems_ref;
            $s_fichierd = $RSSDirname . '/' . $s_fichierd . '.xml';

            # arguement "-l" force a utiliser fichiers locaux
            if ( exists( $h_website2items{$titleOfFeed} ) ) {
                sayDebug("run() $titleOfFeed deja traite");
                $rssItems_ref = $h_website2items{$titleOfFeed};
            }
            elsif ( defined($useLocalRSSFiles) ) {
                $rssItems_ref = readRSSFromFile($s_fichierd);
                $h_website2items{$titleOfFeed} = $rssItems_ref;
            }
            else {
                $rssItems_ref
                    = readRSSFromWeb( $rh_site->{'rss'}, $s_fichierd,
                    $rh_site->{'encoding'} );
                $rssItems_ref = readRSSFromFile($s_fichierd)
                    if !defined($rssItems_ref);
                $h_website2items{$titleOfFeed} = $rssItems_ref;
            }

            # no RSS feed found
            if ( !defined($rssItems_ref) ) {
                $h_website2error{$titleOfFeed} = 1;
                next;
            }
            $rh_zite->{'items'} = $rssItems_ref;
            $rh_zite->{'titre'} = $titleOfFeed;
            $rh_zite->{'url'}   = $rh_site->{url};
            $rh_zite->{'lang'}  = $s_lang;
            push( @a_sites,        $rh_zite );
            push( @$ra_splitSites, $rh_zite );

            # sauve les hachages pour la page "Tout"
            if ( !exists( $h_pageToutFlags{$titleOfFeed} ) ) {
                $h_pageToutFlags{$titleOfFeed} = 1;
                push( @a_Asites,        $rh_zite );
                push( @$ra_AsplitSites, $rh_zite );
                if ( $ra_AsplitSites eq \@a_AleftWebsites ) {
                    $ra_AsplitSites = \@a_ArightWebsites;
                }
                else {
                    $ra_AsplitSites = \@a_AleftWebsites;
                }
            }

            # alterne colonne droite / gauche (page "split")
            if ( $ra_splitSites eq \@a_leftWebsites ) {
                $ra_splitSites = \@a_rightWebsites;
            }
            else {
                $ra_splitSites = \@a_leftWebsites;
            }

        }
        if ( !defined($generateTheAllPage) ) {

            # genere page "une colonne"
            $templateVars_ref->{'titleOfPage'} = $htmlPage_ref->{'titre'};
            $templateVars_ref->{'listemenu'}   = \@menusList;
            $templateVars_ref->{'link2columns'}
                = $menusListSplit[ $pageCounter - 1 ]->{'url'};
            $templateVars_ref->{listOfWebsites} = \@a_sites;
            sayError( $template->error() )
                if (
                !$template->process(
                    'modele.html',
                    $templateVars_ref,
                    $documentRoot . $mainFolder . $s_page
                )
                );

            # genere page "deux colonnes"
            $templateVars_ref->{listemenu} = \@menusListSplit;
            $templateVars_ref->{link1column}
                = $menusList[ $pageCounter - 1 ]->{'url'};
            $templateVars_ref->{leftWebsites}  = \@a_leftWebsites;
            $templateVars_ref->{rightWebsites} = \@a_rightWebsites;
            sayError( $template->error() )
                if (
                !$template->process(
                    'modele-split.html',
                    $templateVars_ref,
                    $documentRoot . $splitFolder . $s_page
                )
                );
        }
    }

    # affiche les sites non traites
    sayDebug( 'run() ' . scalar( keys %h_website2error ) . " site(s) )" );
    foreach ( keys %h_website2error ) {
        my $s_ligne = sprintf( "%-25s", "'$_'" );
        sayError("run() $s_ligne : non traite");
    }

    # toutes les pages genrees ? Donc ne touche pas aux "tout.html"
    return if defined($specificPageRequest);

    # genere la page "tout.html"
    $templateVars_ref->{link2columns}
        = $menusListSplit[ scalar(@menusListSplit) - 1 ]->{url};
    $templateVars_ref->{titleOfPage}    = 'Tout';
    $templateVars_ref->{listOfWebsites} = \@a_Asites;
    $templateVars_ref->{listemenu}      = \@menusList;
    sayError( $template->error() )
        if (
        !$template->process(
            'modele.html', $templateVars_ref,
            $documentRoot . $mainFolder . 'tout.html'
        )
        );

    # genere la page "split/tout.html"
    $templateVars_ref->{listemenu} = \@menusListSplit;
    $templateVars_ref->{link1column}
        = $menusList[ scalar(@menusList) - 1 ]->{url};
    $templateVars_ref->{leftWebsites}  = \@a_AleftWebsites;
    $templateVars_ref->{rightWebsites} = \@a_ArightWebsites;
    sayError( $template->error() )
        if (
        !$template->process(
            'modele-split.html', $templateVars_ref,
            $documentRoot . $splitFolder . 'tout.html'
        )
        );
}

## @method readRSSFromWeb()
# @brief read feed from the Website
# @param $rssUrl URL of the RSS (ie. http://www.linux.com/feature/?theme=rss)
# @param $rssFilename Full pathname of file where store the RSS
# @param $s_encoding
sub readRSSFromWeb {
    my ( $rssUrl, $rssFilename, $encoding ) = @_;
    sayDebug("readRSSFromWeb() HTTP::Request( 'GET' => '$rssUrl' )");
    my $request = new HTTP::Request( 'GET' => $rssUrl );
    $request->header( 'Accept' => $http_ref->{'accept'} );
    my $result = $userAgent->request($request);
    if ( !$result->is_success() ) {
        sayError( 'readRSSFromWeb() '
                . 'LWP::UserAgent::request() failed!'
                . 'URL = '
                . $rssUrl
                . '; code = '
                . $result->code()
                . '; message = '
                . $result->message() );
        return;
    }
    my $code    = '';
    my $content = $result->content();
    if ( defined($encoding) ) {
        $content
            =~ s/<\?xml version="1\.0".*?>/<?xml version="1.0" encoding="$encoding"?>/;
    }
    else {
        $content =~ s/encoding="(iso-8859-15)"/encoding="iso-8859-1"/g;
        if ( defined($1) ) {
            $code = $1;
        }
        else {
            $content =~ /encoding="([^"]+)"/;
            $code = $1 if defined($1);
        }

    }
    sayDebug("readRSSFromWeb() file encoding = '$code'");
    undef($warnError);
    my $rssParser = new XML::RSS();
    if ( !defined($rssParser) ) {
        sayError('(!) readRSSFromWeb(): new XML::RSS() failed');
    }
    eval { $rssParser->parse($content); };
    if ($@) {
        sayError("readRSSFromWeb(): XML::RSS::parse() die: $@");
        return;
    }
    if ($warnError) {
        sayError($warnError);
    }
    sayDebug("readRSSFromWeb() write the '$rssFilename' file");
    my $fh;
    if ( open( $fh, '>' . $rssFilename ) ) {
        print $fh $content;
        close($fh);
    }
    else {
        sayError("readRSSFromWeb() open($rssFilename) return: $!");
    }
    return readRSSS($rssParser);
}

## @method readRSSFromFile()
## @brief
# @param $filename
sub readRSSFromFile {
    my ($filename) = @_;
    sayDebug("readRSSFromFile() tries to read '$filename' file");
    if ( !-e $filename ) {
        sayError("'readRSSFromFile() $filename' file not found!");
        return;
    }
    my $rssParser = new XML::RSS();
    if ( !defined($rssParser) ) {
        sayError('readRSSFromFile() new XML::RSS() failed!');
    }
    eval { $rssParser->parsefile($filename); };
    if ($@) {
        sayError("readRSSFromFile() Parsing error: $@");
        return;
    }
    return readRSSS($rssParser);
}

## @method array = readRSSS(object)
#@brief Inject RSS feed into a hasch table
#@param object A XML::RSS object
#@return array Array of hashs: titles and URL of each item
sub readRSSS {
    my ($o_rssParser) = @_;
    my @items         = ();
    my $counter       = 10;
    foreach my $rh_item ( @{ $o_rssParser->{'items'} } ) {
        my $title = $rh_item->{'title'};
        my $url   = $rh_item->{'link'};
        $url =~ s/&/&amp;/g;
        $title = HTML::Entities::decode_entities($title);
        $title = HTML::Entities::encode_entities($title);
        $title =~ s/&amp;(#\d+)/&$1/g;
        $title =~ s/(\n|\r)//g;
        push(
            @items,
            {   'title' => $title,
                'url'   => $url
            }
        );
        last if ( --$counter < 1 );
    }
    return \@items;
}

## @method getDate()
# @brief Generate date of the day
# return string date of the day (YYYYY-MM-DD)
sub getDate {
    my @a_tmp = localtime(time);
    my $s_datetime
        = ( $a_tmp[5] + 1900 ) . '-'
        . sprintf( "%02d", $a_tmp[4] + 1 ) . '-'
        . sprintf( "%02d", $a_tmp[3] ) . 'T'
        . sprintf( "%02d", $a_tmp[2] ) . ':'
        . sprintf( "%02d", $a_tmp[1] ) . ':'
        . sprintf( "%02d", $a_tmp[0] )
        . '+01:00';

    my $s_date
        = ( $a_tmp[5] + 1900 ) . '-'
        . sprintf( "%02d", $a_tmp[4] + 1 ) . '-'
        . sprintf( "%02d", $a_tmp[3] );
    return ( $s_date, $s_datetime );
}

## @method void makeDirP($dirname, $mode)
# @brief Create a directory
sub makeDirP {
    my ( $dirname, $mode ) = @_;
    $mode = 0755 if !defined $mode;
    my $pos = -1;
    my $currentDir;
    while ( ( $pos = index( $dirname, '/', $pos ) ) > -1 ) {
        $currentDir = substr( $dirname, 0, $pos );
        if ( ( !-d $currentDir ) and length($currentDir) ) {
            die "makeDirP($currentDir) return: $!"
                if !mkdir( $currentDir, $mode );
        }
        $pos++;
    }

    # cree le dernier repertoire
    if ( !-d $dirname ) {
        die "makeDirP($dirname) return: $!"
            if !mkdir( $dirname, $mode );
    }
}

## @method sayDebug(@)
#@brief display message(s)
sub sayDebug {
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    return if !defined $isVerbose;
    setlog('debug',  $message);
    print STDOUT $message ."\n";
}

## @method sayError(@_)
#@brief display error messages
sub sayError {
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    setlog('err',  $message);
    return if !defined($isVerbose);
    print STDERR colored( $message, 'red') . " \n";
}

## @method sayError(@_)
#@brief display error messages
sub sayWarn {
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    setlog('warning',  $message);
    return if !defined($isVerbose);
    print STDOUT colored( $message, 'yellow') . " \n"; 
}

## @method sayError(@_)
#@brief display error messages
sub sayInfo {
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    setlog('info',  $message);
    return if !defined($isVerbose);
    print STDOUT colored( $message, 'blue') . " \n"; 
}

## @method void setlog($priorite, $message)
# @param priorite Level: 'info', 'error', 'debug' or 'warning'
sub setlog {
    my ( $priorite, $message ) = @_;
    if (defined $sysLog_ref) {
        Sys::Syslog::syslog( $priorite, '%s', $message );
        return;
    }
    return if !defined $logFilename;
    my $fh;
    return if !open( $fh, '>>', $logFilename);
    my @ltime = localtime(time);
    my $datetime
        = ( $ltime[5] + 1900 ) . '-'
        . sprintf( "%02d", $ltime[4] + 1 ) . '-'
        . sprintf( "%02d", $ltime[3] ) . 'T'
        . sprintf( "%02d", $ltime[2] ) . ':'
        . sprintf( "%02d", $ltime[1] ) . ':'
        . sprintf( "%02d", $ltime[0] )
        . '+01:00';
    print $fh "$datetime [$$] $message \n";
    close $fh;
}

## @method readArgs()
# @brief Read args
sub readArgs {
    my $res
        = Getopt::Long::GetOptions( 'p:s', \$specificPageRequest, 'v',
        \$isVerbose, 'l', \$useLocalRSSFiles, 't', \$generateTheAllPage );
    if ( defined($specificPageRequest) ) {
        my @pageNums = split( ",", $specificPageRequest );
        $specificPagesRequested{$_} = 1 foreach (@pageNums);
    }
}

## @method init()
# @brief read URLs and titles of each pages (build menu)
sub init {
    readArgs();
    readConfig();
    writeProcessID();
    if ( defined $sysLog_ref ) {
        Sys::Syslog::setlogsock( $sysLog_ref->{'sock_type'} );
        my $ident = $main::0;
        $ident =~ s,^.*/([^/]*)$,$1,;
        Sys::Syslog::openlog(
            $ident,
            "ndelay,$sysLog_ref->{'logopt'}",
            $sysLog_ref->{'facility'}
        );
    }
    $RSSDirname = $documentRoot . $mainFolder . 'RSS';
    $userAgent  = new LWP::UserAgent();
    $userAgent->agent( $http_ref->{'agent'}, $http_ref->{'timeout'} ); 
    $feedPages_ref = readConf( $Bin . '/conf.pl' );
    makeDirP($RSSDirname);
    makeDirP( $documentRoot . $mainFolder );
    makeDirP( $documentRoot . $splitFolder );
    readSections();
    sayWarn("init() recreate only page number $specificPageRequest")
        if defined($specificPageRequest);
}

## @method writeProcessID()
sub writeProcessID {
    if (   !( $pid_handle = new IO::File( '+>' . $pidfile ) )
        || !flock( $pid_handle, LOCK_EX | LOCK_NB ) )

    {
        die "Cannot open or lock pidfile '$pidfile'."
            . "another tooelle.pl running? error: $!";
    }

    if (   !$pid_handle->seek( 0, 0 )
        || !$pid_handle->truncate(0)
        || !$pid_handle->print("$$\n")
        || !$pid_handle->flush() )
    {
        die("Cannot write to '$pidfile'. error: $!");
    }
}

## @method boolean isString($hash_ref, $name)
sub isString {
    my ( $hash_ref, $name ) = @_;
    if (   !exists $hash_ref->{$name}
        or ref( $hash_ref->{$name} )
        or $hash_ref->{$name} !~ m{^.+$} )
    {
        return 0;
    }
    else {
        return 1;
    }
}

## @method void readConfig()
# @brief Read configuration file
sub readConfig {
    my $confFound = 0;
    foreach my $pathname ( $Bin, '/etc', $ENV{'HOME'} . '/.tootella-like' ) {
        my $filename = $pathname . '/' . $configFileName;
        next if !-e $filename;
        my %config = Config::General->new($filename)->getall();
        die "readConfig() 'pid' section not found"
            if !exists $config{'pid'};
        die "readConfig() 'pid/filename' not found or wrong"
            if !isString( $config{'pid'}, 'filename' );
        $pidfile = $config{'pid'}->{'filename'}
            if exists $config{'pid'}->{'filename'};
        die "readConfig() 'web' section not found"
            if !exists $config{'web'};
        my $web_ref = $config{'web'};
        die "readConfig() 'web/documentRoot' not found or wrong"
            if !isString( $web_ref, 'documentRoot' );
        $documentRoot = $web_ref->{'documentRoot'};
        die "readConfig() 'web/folder' not found or wrong"
            if !isString( $web_ref, 'folder' );
        $mainFolder = $web_ref->{'folder'};
        die "readConfig() 'web/split' not found or wrong"
            if !isString( $web_ref, 'split' );
        $splitFolder = $web_ref->{'split'};


        die "readConfig() 'http' section not found"
            if !exists $config{'http'};
        $http_ref = $config{'http'};
        die "readConfig() 'http/agent' not found or wrong"
            if !isString( $http_ref, 'agent' );
        die "readConfig() 'http/timeout' not found or wrong"
            if !isString( $http_ref, 'timeout' );
        die "readConfig() 'http/accept' not found or wrong"
            if !isString( $http_ref, 'accept' );

        if ( exists $config{'syslog'} ) {
            $sysLog_ref = $config{'syslog'};
            die "(!) readConfig(): 'logopt' not found"
              if !isString($sysLog_ref, 'logopt');
            die "(!) readConfig(): 'facility' not found"
              if !isString($sysLog_ref, 'facility');
            die "(!) readConfig(): 'sock_type' not found"
              if !isString($sysLog_ref, 'sock_type');
        }
        if ( exists $config{'log'} ) {
          die "readConfig() 'log/filename' not found or wrong"
            if !isString( $config{'log'}, 'filename' );
            $logFilename = $config{'log'}->{'filename'};
        }
        $confFound = 1;
    }
    die "readConfig() no configuration file has been found!"
        if !$confFound;
}

## @method hash = readConf($filename)
## @brief Read config file (filenames, titles, websites, URLs, feeds)
sub readConf {
    my ($filename) = @_;
    my $stat = stat($filename);
    die $! if !defined($stat);
    my $fh;
    die $! if !open( $fh, '<', $filename );
    my ( $content, $contentLength ) = ( '', 0 );
    sysread( $fh, $content, $stat->size(), $contentLength );
    close($fh);
    my $conf = eval($content);
    die $@ if $@;
    return $conf;
}

## @method void readSections()
# @brief read URLs and titles of each pages (build menu)
sub readSections {
    @menusList = ();
    foreach my $htmlPage_ref (@$feedPages_ref) {
        push(
            @menusList,
            {   url   => '/' . $mainFolder . $htmlPage_ref->{page},
                titre => $htmlPage_ref->{titre}
            }
        );
        push(
            @menusListSplit,
            {   url   => '/' . $splitFolder . $htmlPage_ref->{page},
                titre => $htmlPage_ref->{titre}
            }
        );
    }

    #menus specials "tout.html" et "split/tout.html"
    push(
        @menusList,
        {   url   => '/' . $mainFolder . 'tout.html',
            titre => 'Tout'
        }
    );
    push(
        @menusListSplit,
        {   url   => '/' . $splitFolder . 'tout.html',
            titre => 'Tout'
        }
    );
}



## @method void BEGIN()
sub BEGIN {
    $SIG{'__WARN__'} = sub {
        $warnError = $_[0];
        $warnError =~ s/\n//g;
    };
}

