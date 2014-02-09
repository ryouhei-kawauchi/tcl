# cookiejar.tcl --
#
#	Implementation of an HTTP cookie storage engine using SQLite. The
#	implementation is done as a TclOO class, and includes a punycode
#	encoder and decoder (though only the encoder is currently used).
#
# See the file "license.terms" for information on usage and redistribution of
# this file, and for a DISCLAIMER OF ALL WARRANTIES.

# Dependencies
package require Tcl 8.6
package require http 2.8.4
package require sqlite3
package require tcl::idna 1.0

#
# Configuration for the cookiejar package, plus basic support procedures.
#

namespace eval ::http {
    # Keep this in sync with pkgIndex.tcl and with the install directories in
    # Makefiles
    variable cookiejar_version 0.1

    # TODO: is this the _right_ list of domains to use? Or is there an alias
    # for it that will persist longer?
    variable cookiejar_domainlist \
	http://mxr.mozilla.org/mozilla-central/source/netwerk/dns/effective_tld_names.dat?raw=1
    variable cookiejar_domainfile \
	[file join [file dirname [info script]] effective_tld_names.txt.gz]
    # The list is directed to from http://publicsuffix.org/list/
    variable cookiejar_loglevel info
    variable cookiejar_vacuumtrigger 200
    variable cookiejar_offline false
    variable cookiejar_purgeinterval 60000

    # This is the class that we are creating
    ::oo::class create cookiejar

    # Some support procedures, none particularly useful in general
    namespace eval cookiejar_support {
	# Set up a logger if the http package isn't actually loaded yet.
	if {![llength [info commands ::http::Log]]} {
	    proc ::http::Log args {
		# Do nothing by default...
	    }
	}

	namespace export *
	proc locn {secure domain path {key ""}} {
	    if {$key eq ""} {
		format "%s://%s%s" [expr {$secure?"https":"http"}] \
		    [tcl::idna encode $domain] $path
	    } else {
		format "%s://%s%s?%s" \
		    [expr {$secure?"https":"http"}] [tcl::idna encode $domain] \
		    $path $key
	    }
	}
	proc splitDomain domain {
	    set pieces [split $domain "."]
	    for {set i [llength $pieces]} {[incr i -1] >= 0} {} {
		lappend result [join [lrange $pieces $i end] "."]
	    }
	    return $result
	}
	proc splitPath path {
	    set pieces [split [string trimleft $path "/"] "/"]
	    for {set j -1} {$j < [llength $pieces]} {incr j} {
		lappend result /[join [lrange $pieces 0 $j] "/"]
	    }
	    return $result
	}
	proc isoNow {} {
	    set ms [clock milliseconds]
	    set ts [expr {$ms / 1000}]
	    set ms [format %03d [expr {$ms % 1000}]]
	    clock format $ts -format "%Y%m%dT%H%M%S.${ms}Z" -gmt 1
	}
	proc log {level msg} {
	    namespace upvar ::http cookiejar_loglevel loglevel
	    set who [uplevel 1 self]
	    set map {debug 0 info 1 warn 2 error 3}
	    if {[string map $map $level] >= [string map $map $loglevel]} {
		::http::Log "[isoNow] [string toupper $level] cookiejar($who) - ${msg}"
	    }
	}
	namespace import ::http::cookiejar_support::puny::IDNA*
    }
}

# Now we have enough information to provide the package.
package provide cookiejar $::http::cookiejar_version

# The implementation of the cookiejar package
::oo::define ::http::cookiejar {
    self method loglevel {{level "\u0000\u0000"}} {
	namespace upvar ::http cookiejar_loglevel loglevel
	if {$level in {debug info warn error}} {
	    set loglevel $level
	} elseif {$level ne "\u0000\u0000"} {
	    return -code error "unknown log level \"$level\": must be debug, info, warn, or error"
	}
	return $loglevel
    }

    variable aid deletions
    constructor {{path ""}} {
	namespace import ::http::cookiejar_support::*
	namespace upvar ::http cookiejar_purgeinterval purgeinterval

	if {$path eq ""} {
	    sqlite3 [namespace current]::db :memory:
	    set storeorigin "constructed cookie store in memory"
	} else {
	    sqlite3 [namespace current]::db $path
	    db timeout 500
	    set storeorigin "loaded cookie store from $path"
	}

	set deletions 0
	db eval {
	    --;# Store the persistent cookies in this table.
	    --;# Deletion policy: once they expire, or if explicitly killed.
	    CREATE TABLE IF NOT EXISTS persistentCookies (
		id INTEGER PRIMARY KEY,
		secure INTEGER NOT NULL,
		domain TEXT NOT NULL COLLATE NOCASE,
		path TEXT NOT NULL,
		key TEXT NOT NULL,
		value TEXT NOT NULL,
		originonly INTEGER NOT NULL,
		expiry INTEGER NOT NULL,
		creation INTEGER NOT NULL);
	    CREATE UNIQUE INDEX IF NOT EXISTS persistentUnique
		ON persistentCookies (domain, path, key);
	    CREATE INDEX IF NOT EXISTS persistentLookup
		ON persistentCookies (domain, path);

	    --;# Store the session cookies in this table.
	    --;# Deletion policy: at cookiejar instance deletion, if
	    --;# explicitly killed, or if the number of session cookies is too
	    --;# large and the cookie has not been used recently.
	    CREATE TEMP TABLE sessionCookies (
		id INTEGER PRIMARY KEY,
		secure INTEGER NOT NULL,
		domain TEXT NOT NULL COLLATE NOCASE,
		path TEXT NOT NULL,
		key TEXT NOT NULL,
		originonly INTEGER NOT NULL,
		value TEXT NOT NULL,
		lastuse INTEGER NOT NULL,
		creation INTEGER NOT NULL);
	    CREATE UNIQUE INDEX sessionUnique
		ON sessionCookies (domain, path, key);
	    CREATE INDEX sessionLookup ON sessionCookies (domain, path);

	    --;# View to allow for simple looking up of a cookie.
	    CREATE TEMP VIEW cookies AS
		SELECT id, domain, path, key, value, originonly, secure,
		    1 AS persistent
		    FROM persistentCookies
		UNION
		SELECT id, domain, path, key, value, originonly, secure,
		    0 AS persistent
		    FROM sessionCookies;

	    --;# Encoded domain permission policy; if forbidden is 1, no
	    --;# cookie may be ever set for the domain, and if forbidden is 0,
	    --;# cookies *may* be created for the domain (overriding the
	    --;# forbiddenSuper table).
	    --;# Deletion policy: normally not modified.
	    CREATE TABLE IF NOT EXISTS domains (
		domain TEXT PRIMARY KEY NOT NULL,
		forbidden INTEGER NOT NULL);

	    --;# Domains that may not have a cookie defined for direct child
	    --;# domains of them.
	    --;# Deletion policy: normally not modified.
	    CREATE TABLE IF NOT EXISTS forbiddenSuper (
		domain TEXT PRIMARY KEY);
	}

	set cookieCount "no"
	db eval {
	    SELECT COUNT(*) AS cookieCount FROM persistentCookies
	}
	log info "$storeorigin with $cookieCount entries"

	set aid [after $purgeinterval [namespace current]::my PurgeCookies]

	# TODO: domain list refresh policy
	if {$path ne "" && ![db exists {
	    SELECT 1 FROM domains
	}]} then {
	    my InitDomainList
	}
    }

    method GetDomainListOnline {} {
	upvar 0 ::http::cookiejar_domainlist url
	log debug "loading domain list from $url"
	set tok [::http::geturl $url]
	try {
	    if {[::http::ncode $tok] == 200} {
		return [::http::data $tok]
	    } else {
		log error "failed to fetch list of forbidden cookie domains from ${url}: [::http::error $tok]"
		return {}
	    }
	} finally {
	    ::http::cleanup $tok
	}
    }
    method GetDomainListOffline {} {
	upvar 0 ::http::cookiejar_domainfile filename
	log debug "loading domain list from $filename"
	try {
	    set f [open $filename]
	    try {
		if {[string match *.gz $filename]} {
		    zlib push gunzip $f
		}
		fconfigure $f -encoding utf-8
		return [read $f]
	    } finally {
		close $f
	    }
	} on error {msg opt} {
	    log error "failed to read list of forbidden cookie domains from ${filename}: $msg"
	    return -options $opt $msg
	}
    }
    method InitDomainList {} {
	upvar 0 ::http::cookiejar_offline offline
	if {!$offline} {
	    set data [my GetDomainListOnline]
	    if {[string length $data]} {
		my InstallDomainData $data
		return
	    }
	    log warn "attempting to fall back to built in version"
	}
	my InstallDomainData [my GetDomainListOffline]
    }

    method InstallDomainData {data} {
	set n [db total_changes]
	db transaction {
	    foreach line [split $data "\n"] {
		if {[string trim $line] eq ""} {
		    continue
		} elseif {[string match //* $line]} {
		    continue
		} elseif {[string match !* $line]} {
		    set line [string range $line 1 end]
		    set idna [string tolower [tcl::idna encode $line]]
		    set utf [tcl::idna decode [string tolower $line]]
		    db eval {
			INSERT OR REPLACE INTO domains (domain, forbidden)
			VALUES ($utf, 0);
		    }
		    if {$idna ne $utf} {
			db eval {
			    INSERT OR REPLACE INTO domains (domain, forbidden)
			    VALUES ($idna, 0);
			}
		    }
		} else {
		    if {[string match {\*.*} $line]} {
			set line [string range $line 2 end]
			set idna [string tolower [tcl::idna encode $line]]
			set utf [tcl::idna decode [string tolower $line]]
			db eval {
			    INSERT OR REPLACE INTO forbiddenSuper (domain)
			    VALUES ($utf);
			}
			if {$idna ne $utf} {
			    db eval {
				INSERT OR REPLACE INTO forbiddenSuper (domain)
				VALUES ($idna);
			    }
			}
		    } else {
			set idna [string tolower [tcl::idna encode $line]]
			set utf [tcl::idna decode [string tolower $line]]
		    }
		    db eval {
			INSERT OR REPLACE INTO domains (domain, forbidden)
			VALUES ($utf, 1);
		    }
		    if {$idna ne $utf} {
			db eval {
			    INSERT OR REPLACE INTO domains (domain, forbidden)
			    VALUES ($idna, 1);
			}
		    }
		}
		if {$utf ne [tcl::idna decode [string tolower $idna]]} {
		    log warn "mismatch in IDNA handling for $idna ($line, $utf, [tcl::idna decode $idna])"
		}
	    }
	}
	set n [expr {[db total_changes] - $n}]
	log debug "processed $n inserts generated from domain list"
    }

    # This forces the rebuild of the domain data, loading it from 
    method forceLoadDomainData {} {
	db transaction {
	    db eval {
		DELETE FROM domains;
		DELETE FROM forbiddenSuper;
	    }
	    my InitDomainList
	}
    }

    destructor {
	after cancel $aid
	db close
    }

    method GetCookiesForHostAndPath {listVar secure host path fullhost} {
	upvar 1 $listVar result
	log debug "check for cookies for [locn $secure $host $path]"
	db eval {
	    SELECT key, value FROM persistentCookies
	    WHERE domain = $host AND path = $path AND secure <= $secure
	    AND (NOT originonly OR domain = $fullhost)
	} {
	    lappend result $key $value
	}
	set now [clock seconds]
	db eval {
	    SELECT id, key, value FROM sessionCookies
	    WHERE domain = $host AND path = $path AND secure <= $secure
	    AND (NOT originonly OR domain = $fullhost)
	} {
	    lappend result $key $value
	    db eval {
		UPDATE sessionCookies SET lastuse = $now WHERE id = $id
	    }
	}
    }

    method getCookies {proto host path} {
	set result {}
	set paths [splitPath $path]
	set domains [splitDomain [string tolower [tcl::idna encode $host]]]
	set secure [string equal -nocase $proto "https"]
	# Open question: how to move these manipulations into the database
	# engine (if that's where they *should* be).
	#
	# Suggestion from kbk:
	#LENGTH(theColumn) <= LENGTH($queryStr) AND
	#SUBSTR(theColumn, LENGTH($queryStr) LENGTH(theColumn)+1) = $queryStr
	#
	# However, we instead do most of the work in Tcl because that lets us
	# do the splitting exactly right, and it's far easier to work with
	# strings in Tcl than in SQL.
	db transaction {
	    if {[regexp {[^0-9.]} $host]} {
		foreach domain $domains {
		    foreach p $paths {
			my GetCookiesForHostAndPath result $secure $domain $p $host
		    }
		}
	    } else {
		# Ugh, it's a numeric domain! Restrict it...
		foreach p $paths {
		    my GetCookiesForHostAndPath result $secure $host $p $host
		}
	    }
	}
	return $result
    }

    method BadDomain options {
	if {![dict exists $options domain]} {
	    return 0
	}
	dict with options {}
	if {$domain ne $origin} {
	    log debug "cookie domain varies from origin ($domain, $origin)"
	}
	if {![regexp {[^0-9.]} $domain]} {
	    if {$domain eq $origin} {
		# May set for itself
		return 0
	    }
	    log warn "bad cookie: for a numeric address"
	    return 1
	}
	db eval {
	    SELECT forbidden FROM domains WHERE domain = $domain
	} {
	    if {$forbidden} {
		log warn "bad cookie: for a forbidden address"
	    }
	    return $forbidden
	}
	if {[regexp {^[^.]+\.(.+)$} $domain -> super] && [db exists {
	    SELECT 1 FROM forbiddenSuper WHERE domain = $super
	}]} then {
	    log warn "bad cookie: for a forbidden address"
	    return 1
	}
	return 0
    }

    method storeCookie {name val options} {
	set now [clock seconds]
	db transaction {
	    if {[my BadDomain $options]} {
		return
	    }
	    set now [clock seconds]
	    dict with options {}
	    if {!$persistent} {
		db eval {
		    INSERT OR REPLACE INTO sessionCookies (
			secure, domain, path, key, value, originonly, creation, lastuse)
		    VALUES ($secure, $domain, $path, $key, $value, $hostonly, $now, $now);
		    DELETE FROM persistentCookies
		    WHERE domain = $domain AND path = $path AND key = $key AND secure <= $secure
		}
		incr deletions [db changes]
		log debug "defined session cookie for [locn $secure $domain $path $key]"
	    } elseif {$expires < $now} {
		db eval {
		    DELETE FROM persistentCookies
		    WHERE domain = $domain AND path = $path AND key = $key
			AND secure <= $secure;
		}
		set del [db changes]
		db eval {
		    DELETE FROM sessionCookies
		    WHERE domain = $domain AND path = $path AND key = $key
			AND secure <= $secure;
		}
		incr deletions [incr del [db changes]]
		log debug "deleted $del cookies for [locn $secure $domain $path $key]"
	    } else {
		db eval {
		    INSERT OR REPLACE INTO persistentCookies (
			secure, domain, path, key, value, originonly, expiry, creation)
		    VALUES ($secure, $domain, $path, $key, $value, $hostonly, $expires, $now);
		    DELETE FROM sessionCookies
		    WHERE domain = $domain AND path = $path AND key = $key AND secure <= $secure
		}
		incr deletions [db changes]
		log debug "defined persistent cookie for [locn $secure $domain $path $key], expires at [clock format $expires]"
	    }
	}
    }

    method PurgeCookies {} {
	namespace upvar ::http \
	    cookiejar_vacuumtrigger trigger \
	    cookiejar_purgeinterval interval
	set aid [after $interval [namespace current]::my PurgeCookies]
	set now [clock seconds]
	log debug "purging cookies that expired before [clock format $now]"
	db transaction {
	    db eval {
		DELETE FROM persistentCookies WHERE expiry < $now
	    }
	    incr deletions [db changes]
	}
	### TODO: Cap the total number of cookies and session cookies,
	### purging least frequently used

	# Once we've deleted a fair bit, vacuum the database. Must be done
	# outside a transaction.
	if {$deletions > $trigger} {
	    set deletions 0
	    log debug "vacuuming cookie database"
	    catch {
		db eval {
		    VACUUM
		}
	    }
	}
    }

    forward Database db

    method lookup {{host ""} {key ""}} {
	set host [string tolower [tcl::idna encode $host]]
	db transaction {
	    if {$host eq ""} {
		set result {}
		db eval {
		    SELECT DISTINCT domain FROM cookies
		    ORDER BY domain
		} {
		    lappend result [tcl::idna decode [string tolower $domain]]
		}
		return $result
	    } elseif {$key eq ""} {
		set result {}
		db eval {
		    SELECT DISTINCT key FROM cookies
		    WHERE domain = $host
		    ORDER BY key
		} {
		    lappend result $key
		}
		return $result
	    } else {
		db eval {
		    SELECT value FROM cookies
		    WHERE domain = $host AND key = $key
		    LIMIT 1
		} {
		    return $value
		}
		return -code error "no such key for that host"
	    }
	}
    }
}

# Local variables:
# mode: tcl
# fill-column: 78
# End: