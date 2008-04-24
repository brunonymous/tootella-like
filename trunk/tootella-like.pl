#!/usr/bin/perl
# @author Bruno Ethvignot <bruno at tlk.biz>
# @created 2005-05-03
# @date 2008-05-24
#
# copyright (c) 2008 TLK Games all rights reserved
# $Id: imap2signal-spam.pl 16 2008-04-12 09:38:08Z bruno.ethvignot $
#
# imap2signal-spam is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# imap2signal-spam is distributed in the hope that it will be useful, but
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
use diagnostics;
use Data::Dumper;
use FindBin qw($Bin);
use Fcntl qw(:DEFAULT :flock);
use File::stat;
use Getopt::Long;
use HTML::Entities;
use LWP::UserAgent;
use POSIX ":sys_wait_h";
use IO::File;
use Template;
use XML::RSS;

my $pid_handle;
my $configFileName = 'tootella-like.conf';
my $documentRoot   = './bubux/';
my $s_folder       = 'pages/';
my $s_foldersplit  = 'pages/split/';
## -l option: Use local RSS files is forced l
my $useLocalRSSFiles;
## -v option: verbose mode
my $isVerbose;
## -t option: generates only the "tout.html" page
my $generateTheAllPage;
my $s_pageNum;    #option -p : numeros des pages (generer 1 a 8)
my %h_pageNum;    #option -p : liste des pages a taiter (-p 2, 3, 6)

my $s_erreur_warn;
my $userAgent;
my $ra_conf;
my $RSSDirname;
my @a_listemenu;
my @a_listemenuSplit;
my $rh_zite;
my $startTime = time;
my $pidfile;

init();
exit;
runtime();
sayMessage( "(*) Time of execution: " . ( time - $startTime ) . " seconds" );

## @method readArgs()
# @brief Read args
sub readArgs {
    my $s_resultat =
      Getopt::Long::GetOptions( 'p:s', \$s_pageNum, 'v', \$isVerbose, 'l',
        \$useLocalRSSFiles, 't', \$generateTheAllPage );
    if ( defined($s_pageNum) ) {
        my @a_pageNum = split( ",", $s_pageNum );
        $h_pageNum{$_} = 1 foreach (@a_pageNum);
        sayMessage("(*) recreate only page number $s_pageNum");
    }
}

## @method void = initialize()
# @brief read URLs and titles of each pages (build menu)
sub initialize {
    $RSSDirname  = $documentRoot . $s_folder . 'RSS';
    $userAgent = new LWP::UserAgent();
    $userAgent->agent( 'Mozilla/5.0 (X11; U; Linux ppc; en-US; rv:1.7.6) '
          . 'Gecko/20050328 Firefox/1.0.2' );
    $ra_conf = readConf( $Bin . '/conf.pl' );
    createDir($RSSDirname);
    createDir( $documentRoot . $s_folder );
    createDir( $documentRoot . $s_foldersplit );
    return 1;
}

## @method void createDir($dirname)
# @brief Create directory if not exists
sub createDir {
    my ($dirName) = @_;
    return if -d $dirName;
    die "createDir($dirName) failed!" . "mkdir($dirName) return: $! "
      if !mkdir($dirName);
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
    @a_listemenu = ();
    foreach my $rh_page (@$ra_conf) {
        push(
            @a_listemenu,
            {
                url   => '/' . $s_folder . $rh_page->{page},
                titre => $rh_page->{titre}
            }
        );
        push(
            @a_listemenuSplit,
            {
                url   => '/' . $s_foldersplit . $rh_page->{page},
                titre => $rh_page->{titre}
            }
        );
    }

    #menus specials "tout.html" et "split/tout.html"
    push(
        @a_listemenu,
        {
            url   => '/' . $s_folder . 'tout.html',
            titre => 'Tout'
        }
    );
    push(
        @a_listemenuSplit,
        {
            url   => '/' . $s_foldersplit . 'tout.html',
            titre => 'Tout'
        }
    );
}

## @method void runtime()
# @brief main loop / create all HTML pages
sub runtime {

    # cree nos objets
    my $o_rss    = new XML::RSS();
    my $template = Template->new(
        {
            EVAL_PERL    => 0,
            INCLUDE_PATH => $Bin . '/templates'
        }
    );

    # le hachage "rh_vars" sont les variables pour le Template
    my $rh_vars = {};
    my ( $s_date, $s_datetime ) = getDate();

    # la date est valable pour toutes les pages
    $rh_vars->{date}     = $s_date;
    $rh_vars->{datetime} = $s_datetime;

    # hachage des sites deja traites
    my %h_website2items = ();    #evite de traiter 2 fois le meme fil
    my %h_website2error = ();

    #liste des sites pour les 2 pages "tout.html"
    my @a_Asites         = ();                #1 column : websites list
    my @a_AleftWebsites  = ();                #2 columns : websites at left
    my @a_ArightWebsites = ();                #2 columns : websites at right
    my $ra_AsplitSites   = \@a_AleftWebsites;
    my %h_pageToutFlags  = ();                #evite d'avoir 2 fois le meme site

    # loop of each HTML page
    my $s_compteurPage = 0;    #page counter 1 to n (n = 8 currently)
    foreach my $rh_page (@$ra_conf) {
        $s_compteurPage++;
        if ( defined($s_pageNum) ) {
            next if ( !exists( $h_pageNum{$s_compteurPage} ) );
        }
        my $s_page = $rh_page->{page};
        sayMessage("(*) traite page : $s_page");
        my $ra_sites        = $rh_page->{sites};
        my @a_sites         = ();               #one column : websites list
        my @a_leftWebsites  = ();               #two columns : websites at left
        my @a_rightWebsites = ();               #tow columns : websites at right
        my $ra_splitSites   = \@a_leftWebsites;

        # loop oh each website
        foreach my $rh_site (@$ra_sites) {
            my $s_titreSite = $rh_site->{titre};
            sayMessage("- traite site $s_titreSite");
            my $s_lang;
            if ( exists( $rh_site->{lang} ) ) {
                $s_lang = $rh_site->{lang};
            }
            else {
                $s_lang = 'fr';
                sayError("pas de code langue");
            }
            if ( !length( $rh_site->{rss} ) ) {
                $h_website2error{$s_titreSite} = 1;
                next;
            }
            $rh_zite = {};
            my $s_rss = $rh_site->{rss};

            # genere le nom du fichier local RSS
            my $s_fichierd = $s_titreSite;
            $s_fichierd =~ s/(&eacute;|&egrave;|&ecirc;)/e/g;
            $s_fichierd =~ s/(&aacute;|&agrave;|&acirc;)/a/g;
            $s_fichierd = lc($s_fichierd);
            $s_fichierd =~ s/\s+/-/g;
            $s_fichierd =~ s/\-+/-/g;
            my $ra_items;
            $s_fichierd = $RSSDirname . '/' . $s_fichierd . '.xml';

            # arguement "-l" force a utiliser fichiers locaux
            if ( exists( $h_website2items{$s_titreSite} ) ) {
                sayMessage("- $s_titreSite deja traite");
                $ra_items = $h_website2items{$s_titreSite};
            }
            elsif ( defined($useLocalRSSFiles) ) {
                $ra_items = readRSSFromFile( $o_rss, $s_fichierd );
                $h_website2items{$s_titreSite} = $ra_items;
            }
            else {
                $ra_items = readRSSFromWeb(
                    $o_rss,      $rh_site->{rss},
                    $s_fichierd, $rh_site->{encoding}
                );
                $ra_items = readRSSFromFile( $o_rss, $s_fichierd )
                  if ( !defined($ra_items) );
                $h_website2items{$s_titreSite} = $ra_items;
            }
            if ( !defined($ra_items) ) {    #erreur : pas de fil RSS
                $h_website2error{$s_titreSite} = 1;
                next;
            }
            $rh_zite->{items} = $ra_items;
            $rh_zite->{titre} = $s_titreSite;
            $rh_zite->{url}   = $rh_site->{url};
            $rh_zite->{lang}  = $s_lang;
            push( @a_sites,        $rh_zite );
            push( @$ra_splitSites, $rh_zite );

            # sauve les hachages pour la page "Tout"
            if ( !exists( $h_pageToutFlags{$s_titreSite} ) ) {
                $h_pageToutFlags{$s_titreSite} = 1;
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
            $rh_vars->{titleOfPage} = $rh_page->{titre};
            $rh_vars->{listemenu}   = \@a_listemenu;
            $rh_vars->{link2columns} =
              $a_listemenuSplit[ $s_compteurPage - 1 ]->{url};
            $rh_vars->{listOfWebsites} = \@a_sites;
            sayError( $template->error() )
              if (
                !$template->process(
                    'modele.html', $rh_vars,
                    $documentRoot . $s_folder . $s_page
                )
              );

            # genere page "deux colonnes"
            $rh_vars->{listemenu} = \@a_listemenuSplit;
            $rh_vars->{link1column} =
              $a_listemenu[ $s_compteurPage - 1 ]->{url};
            $rh_vars->{leftWebsites}  = \@a_leftWebsites;
            $rh_vars->{rightWebsites} = \@a_rightWebsites;
            sayError( $template->error() )
              if (
                !$template->process(
                    'modele-split.html', $rh_vars,
                    $documentRoot . $s_foldersplit . $s_page
                )
              );
        }
    }

    # affiche les sites non traites
    sayMessage(
        "--> " . scalar( keys %h_website2error ) . " site(s) non traite(s)" );
    foreach ( keys %h_website2error ) {
        my $s_ligne = sprintf( "%-25s", "'$_'" );
        sayError("--> $s_ligne : non traite");
    }

    # toutes les pages genrees ? Donc ne touche pas aux "tout.html"
    return if ( defined($s_pageNum) );

    # genere la page "tout.html"
    $rh_vars->{link2columns} =
      $a_listemenuSplit[ scalar(@a_listemenuSplit) - 1 ]->{url};
    $rh_vars->{titleOfPage}    = 'Tout';
    $rh_vars->{listOfWebsites} = \@a_Asites;
    $rh_vars->{listemenu}      = \@a_listemenu;
    sayError( $template->error() )
      if (
        !$template->process(
            'modele.html', $rh_vars,
            $documentRoot . $s_folder . 'tout.html'
        )
      );

    # genere la page "split/tout.html"
    $rh_vars->{listemenu}     = \@a_listemenuSplit;
    $rh_vars->{link1column}   = $a_listemenu[ scalar(@a_listemenu) - 1 ]->{url};
    $rh_vars->{leftWebsites}  = \@a_AleftWebsites;
    $rh_vars->{rightWebsites} = \@a_ArightWebsites;
    sayError( $template->error() )
      if (
        !$template->process(
            'modele-split.html', $rh_vars,
            $documentRoot . $s_foldersplit . 'tout.html'
        )
      );
}

## @method readRSSFromWeb()
# @brief read feed from the Website
sub readRSSFromWeb {
    my ( $o_rssParser, $s_rss, $s_fichier, $s_encoding ) = @_;
    sayMessage("- get  $s_rss");
    my $request = new HTTP::Request( 'GET' => $s_rss );
    $request->header( 'Accept' => 'text/html' );
    my $o_res = $userAgent->request($request);
    if ( !$o_res->is_success() ) {
        sayError( '(!) [' 
              . $s_rss . '] '
              . $o_res->code() . ' '
              . $o_res->message() );
        return;
    }
    my $s_code    = '';
    my $s_contenu = $o_res->content();
    if ( defined($s_encoding) ) {
        $s_contenu =~
s/<\?xml version="1\.0".*?>/<?xml version="1.0" encoding="$s_encoding"?>/;
    }
    else {
        $s_contenu =~ s/encoding="(iso-8859-15)"/encoding="iso-8859-1"/g;
        if ( defined($1) ) {
            $s_code = $1;
        }
        else {
            $s_contenu =~ /encoding="([^"]+)"/;
            $s_code = $1 if ( defined($1) );
        }

    }
    sayMessage("> encodage: $s_code");
    undef($s_erreur_warn);
    eval { $o_rssParser->parse($s_contenu); };
    if ($@) {
        sayError("Parsing error: $@");
        return;
    }
    if ($s_erreur_warn) {
        sayError($s_erreur_warn);
    }
    sayMessage("- write $s_fichier");
    if ( open( FICHIER, '>' . $s_fichier ) ) {
        print FICHIER $s_contenu;
        close(FICHIER);
    }
    else {
        sayError($!);
    }
    return readRSSS($o_rssParser);
}

##@method readRSSFromFile()
sub readRSSFromFile {
    my ( $o_rssParser, $s_fichier ) = @_;
    sayMessage("- read file: $s_fichier");
    if ( !-e $s_fichier ) {
        sayError("$s_fichier est inexistant");
        return;
    }
    eval { $o_rssParser->parsefile($s_fichier); };
    if ($@) {
        sayError("Parsing error: $@");
        return;
    }

    #print Dumper($o_rssParser);
    return readRSSS($o_rssParser);
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
            {
                'title' => $title,
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
    my $s_datetime =
        ( $a_tmp[5] + 1900 ) . '-'
      . sprintf( "%02d", $a_tmp[4] + 1 ) . '-'
      . sprintf( "%02d", $a_tmp[3] ) . 'T'
      . sprintf( "%02d", $a_tmp[2] ) . ':'
      . sprintf( "%02d", $a_tmp[1] ) . ':'
      . sprintf( "%02d", $a_tmp[0] )
      . '+01:00';

    my $s_date =
        ( $a_tmp[5] + 1900 ) . '-'
      . sprintf( "%02d", $a_tmp[4] + 1 ) . '-'
      . sprintf( "%02d", $a_tmp[3] );
    return ( $s_date, $s_datetime );
}

## @method sayMessage(@)
#@brief display message(s)
sub sayMessage {
    return if !defined $isVerbose;
    print STDOUT $_ foreach (@_);
    print "\n";
}

## @method sayError(@_)
#@brief display error messages
sub sayError {
    my $fh;
    return if !open( $fh, '>>', '/tmp/tootella.txt' );
    my @a_tmp = localtime(time);
    my $s_datetime =
        ( $a_tmp[5] + 1900 ) . '-'
      . sprintf( "%02d", $a_tmp[4] + 1 ) . '-'
      . sprintf( "%02d", $a_tmp[3] ) . 'T'
      . sprintf( "%02d", $a_tmp[2] ) . ':'
      . sprintf( "%02d", $a_tmp[1] ) . ':'
      . sprintf( "%02d", $a_tmp[0] )
      . '+01:00';
    print $fh "$s_datetime\n";
    print $fh "$_" foreach (@_);
    print $fh "\n";
    close $fh;
    return if ( !defined($isVerbose) );
    print STDERR "$_" foreach (@_);
    print "\n";
}

sub init {
    readArgs();
    readConfig();
    writeProcessID();
    exit if !initialize();
    readSections();
}

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


sub isString {
    my ($hash_ref, $name) = @_;
    if (!exists $hash_ref->{$name}
        or ref($hash_ref->{$name})
        or $hash_ref->{$name} !~m{^.+$}) {
        return 0;
    } else {
       return 1;
    }
}

## @method void readConfig()
# @brief Read configuration file
sub readConfig {
    my $confFound = 0;
    foreach my $pathname ( '.', '/etc', $ENV{'HOME'} . '/.tootella-like' ) {
        my $filename = $pathname . '/' . $configFileName;
        next if !-e $filename;
        my %config = Config::General->new($filename)->getall();
        print Dumper \%config;
        die "readConfig() 'pid' section not found"
            if !exists $config{'pid'};
        die "readConfig() 'pid/filename' not found or wrong"
            if !exists $config{'pid'};
        $pidfile = $config{'pid'}->{'filename'}
          if exists $config{'pid'}->{'filename'};
        $confFound = 1;
    }
    die "(!) readConfig(): no configuration file has been found!"
      if !$confFound;
}

## @method void BEGIN()
sub BEGIN {
    $SIG{'__WARN__'} = sub {
        $s_erreur_warn = $_[0];
        $s_erreur_warn =~ s/\n//g;
    };
}



