
###
# XML::SAX::Writer - SAX2 XML Writer
# Robin Berjon <robin@knowscape.com>
# 26/11/2001 - v.0.02
###

package XML::SAX::Writer;
use strict;
use Text::Iconv             qw();
use XML::NamespaceSupport   qw();
use XML::SAX::Exception     qw();
@XML::SAX::Writer::Exception::ISA = qw(XML::SAX::Exception);

use vars qw($VERSION %DEFAULT_ESCAPE);
$VERSION = '0.02';
%DEFAULT_ESCAPE = (
                    '&'     => '&amp;',
                    '<'     => '&lt;',
                    '>'     => '&gt;',
                    '"'     => '&quot;',
                    "'"     => '&apos;',
                    '--'    => '&#45;&#45;',
                  );


# NOTES
#   I think that the quote character should be an option between '
#   and " (checked for sanity). It currently uses the far superior ',
#   but given that I'm the only person in the qwerty world sane enough
#   to use that by default (hey, it's one less Shift key to hit) I
#   guess that providing the option would be nice.
#
#   The pretty printing could perhaps be better expressed as a filter
#   which would be returned instead of the handler, and fire off the
#   appropriate events. This would have the cool advantage that people
#   would easily be able to add their own pretty printing filters by
#   subclassing the provided one.


#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $opt   = (@_ == 1)  ? { %{shift()} } : {@_};

    # default the options
    $opt->{Escape}      ||= \%DEFAULT_ESCAPE;
    $opt->{EncodeFrom}  ||= 'utf-8';
    $opt->{EncodeTo}    ||= 'utf-8';
    $opt->{Format}      ||= {}; # needs options w/ defaults, we'll see later
    $opt->{Output}      ||= \*STDOUT;

    return bless $opt, $class;
}
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The SAX Handler `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

#-------------------------------------------------------------------#
# start_document
#-------------------------------------------------------------------#
sub start_document {
    my $self = shift;

    # init the object
    $self->{Encoder} = Text::Iconv->new($self->{EncodeFrom}, $self->{EncodeTo});

    $self->{EscaperRegex} = eval 'qr/'                                                .
                            join( '|', map { $_ = "\Q$_\E" } keys %{$self->{Escape}}) .
                            '/;'                                                  ;

    $self->{NSDecl} = [];
    $self->{NSHelper} = XML::NamespaceSupport->new({ xmlns => 1, fatal_errors => 0 });
    $self->{NSHelper}->pushContext;


    # create the Consumer
    if (ref $self->{Output} eq 'SCALAR') {
        $self->{Consumer} = XML::SAX::Writer::StringConsumer->new($self->{Output});
    }
    elsif (ref $self->{Output} eq 'ARRAY') {
        $self->{Consumer} = XML::SAX::Writer::ArrayConsumer->new($self->{Output});
    }
    elsif (ref $self->{Output} eq 'IO') {
        $self->{Consumer} = XML::SAX::Writer::HandleConsumer->new($self->{Output});
    }
    elsif (not ref $self->{Output}) {
        $self->{Consumer} = XML::SAX::Writer::FileConsumer->new($self->{Output});
    }
    elsif (ref $self->{Output}) {
        $self->{Consumer} = $self->{Output};
    }
    else {
        XML::SAX::Writer::Exception->throw({ Message => 'Unknown option for Output' });
    }
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_document
#-------------------------------------------------------------------#
sub end_document {
    my $self = shift;
    # we may need to do a little more here
    $self->{NSHelper}->popContext;
    return $self->{Consumer}->finalize;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# start_element
#-------------------------------------------------------------------#
sub start_element {
    my $self = shift;
    my $data = shift;
    $self->_output_element;
    my $attr = $data->{Attributes};

    # fix the namespaces and prefixes of what we're receiving, in case
    # something is wrong
    if ($data->{NamespaceURI}) {
        my $uri = $self->{NSHelper}->getURI($data->{Prefix});
        if ($uri ne $data->{NamespaceURI}) { # ns has precedence
            $data->{Prefix} = $self->{NSHelper}->getPrefix($data->{NamespaceURI}); # random, but correct
            $data->{Name} = $data->{Prefix} ? "$data->{Prefix}:$data->{LocalName}" : "$data->{LocalName}";
        }
    }
    elsif ($data->{Prefix}) { # we can't have a prefix and no NS
        $data->{Name}   = $data->{LocalName};
        $data->{Prefix} = '';
    }

    for my $at (values %$attr) {
        if ($at->{NamespaceURI}) {
            my $uri = $self->{NSHelper}->getURI($at->{Prefix});
            if ($uri ne $at->{NamespaceURI}) { # ns has precedence
                $at->{Prefix} = $self->{NSHelper}->getPrefix($at->{NamespaceURI}); # random, but correct
                $at->{Name} = $at->{Prefix} ? "$at->{Prefix}:$at->{LocalName}" : "$at->{LocalName}";
            }
        }
        elsif ($at->{Prefix}) { # we can't have a prefix and no NS
            $at->{Name}   = $at->{LocalName};
            $at->{Prefix} = '';
        }
    }


    # grab the NSDecl, add the appropriate attributes, and reset it
    for my $nd (@{$self->{NSDecl}}) {
        if ($nd->{Prefix}) {
            $attr->{'{}xmlns:' . $nd->{Prefix}} = {
                                                    Name    => 'xmlns:' . $nd->{Prefix},
                                                    Value   => $nd->{NamespaceURI},
                                                  };
        }
        else {
            $attr->{'{}xmlns'} = {
                                    Name    => 'xmlns',
                                    Value   => $nd->{NamespaceURI},
                                 };
        }
    }
    $self->{NSDecl} = [];

    # build a string from what we have, and buffer it
    my $el = '<' . $data->{Name};
    for my $at (values %$attr) {
        $el .= ' ' . $at->{Name} . '=\'' . $self->_escape($at->{Value}) . '\'';
    }

    $self->{BufferElement} = $el;
    $self->{NSHelper}->pushContext;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_element
#-------------------------------------------------------------------#
sub end_element {
    my $self = shift;
    my $data = shift;

    my $el;
    if ($self->{BufferElement}) {
        $el = $self->{BufferElement} . ' />';
    }
    else {
        $el = '</' . $data->{Name} . '>';
    }
    $el = $self->{Encoder}->convert($el);
    $self->{Consumer}->output($el);
    $self->{NSHelper}->popContext;
    $self->{BufferElement} = '';
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# characters
#-------------------------------------------------------------------#
sub characters {
    my $self = shift;
    my $data = shift;
    $self->_output_element;

    my $char = $data->{Data};
    $char = $self->_escape($char) unless $self->{InCDATA};
    $char = $self->{Encoder}->convert($char);
    $self->{Consumer}->output($char);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# start_prefix_mapping
#-------------------------------------------------------------------#
sub start_prefix_mapping {
    my $self = shift;
    my $data = shift;

    push @{$self->{NSDecl}}, $data;
    $self->{NSHelper}->declarePrefix($data->{Prefix}, $data->{NamespaceURI});
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_prefix_mapping
#-------------------------------------------------------------------#
sub end_prefix_mapping {}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# processing_instruction
#-------------------------------------------------------------------#
sub processing_instruction {
    my $self = shift;
    my $data = shift;
    $self->_output_element;

    my $pi = "<?$data->{Target} $data->{Data}?>";
    $pi = $self->{Encoder}->convert($pi);
    $self->{Consumer}->output($pi);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# ignorable_whitespace
#-------------------------------------------------------------------#
sub ignorable_whitespace {
    my $self = shift;
    my $data = shift;
    $self->_output_element;

    my $char = $data->{Data};
    $char = $self->_escape($char);
    $char = $self->{Encoder}->convert($char);
    $self->{Consumer}->output($char);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# skipped_entity
#-------------------------------------------------------------------#
sub skipped_entity {
    my $self = shift;
    my $data = shift;
    $self->_output_element; # needed ???
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# notation_decl
#-------------------------------------------------------------------#
sub notation_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# unparsed_entity_decl
#-------------------------------------------------------------------#
sub unparsed_entity_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# element_decl
#-------------------------------------------------------------------#
sub element_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# attribute_decl
#-------------------------------------------------------------------#
sub attribute_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# internal_entity_decl
#-------------------------------------------------------------------#
sub internal_entity_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# external_entity_decl
#-------------------------------------------------------------------#
sub external_entity_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# comment
#-------------------------------------------------------------------#
sub comment {
    my $self = shift;
    my $data = shift;
    $self->_output_element;

    my $cmt = '<!--' . $self->_escape($data->{Data}) . '-->';
    $cmt = $self->{Encoder}->convert($cmt);
    $self->{Consumer}->output($cmt);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# start_dtd
#-------------------------------------------------------------------#
sub start_dtd {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_dtd
#-------------------------------------------------------------------#
sub end_dtd {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# start_cdata
#-------------------------------------------------------------------#
sub start_cdata {
    my $self = shift;
    $self->_output_element;

    $self->{InCDATA} = 1;
    my $cds = $self->{Encoder}->convert('<![CDATA[');
    $self->{Consumer}->output($cds);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_cdata
#-------------------------------------------------------------------#
sub end_cdata {
    my $self = shift;

    $self->{InCDATA} = 0;
    my $cds = $self->{Encoder}->convert(']]>');
    $self->{Consumer}->output($cds);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# start_entity
#-------------------------------------------------------------------#
sub start_entity {
    my $self = shift;
    my $data = shift;
    $self->_output_element; # needed ???
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_entity
#-------------------------------------------------------------------#
sub end_entity {
    my $self = shift;
    my $data = shift;
    $self->_output_element; # needed ???
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#


### SAX1 stuff ######################################################

#-------------------------------------------------------------------#
# xml_decl
#-------------------------------------------------------------------#
sub xml_decl {
    my $self = shift;
    my $data = shift;

    # version info is compulsory, contrary to what some seem to think
    # also, there's order in the pseudo-attr
    my $xd = '';
    if ($data->{Version}) {
        $xd .= "<?xml version='$data->{Version}'";
        if ($data->{Encoding}) {
            $xd .= " encoding='$data->{Encoding}'";
        }
        if ($data->{Standalone}) {
            $xd .= " standalone='$data->{Standalone}'";
        }
        $xd .= '?>';
    }

    $xd = $self->{Encoder}->convert($xd); # this may blow up
    $self->{Consumer}->output($xd);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# attlist_decl
#-------------------------------------------------------------------#
sub attlist_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# doctype_decl
#-------------------------------------------------------------------#
sub doctype_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# entity_decl
#-------------------------------------------------------------------#
sub entity_decl {
    my $self = shift;
    my $data = shift;
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# entity_reference
#-------------------------------------------------------------------#
sub entity_reference {
    my $self = shift;
    my $data = shift;
    $self->_output_element; # needed ???
    warn "[XML::SAX::Writer] this SAX event hasn't been implemented yet\n";
}
#-------------------------------------------------------------------#



#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, Helpers `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

#-------------------------------------------------------------------#
# _output_element
#-------------------------------------------------------------------#
sub _output_element {
    my $self = shift;

    if ($self->{BufferElement}) {
        my $el = $self->{BufferElement} . '>';
        $el = $self->{Encoder}->convert($el);
        $self->{Consumer}->output($el);
        $self->{BufferElement} = '';
    }
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# _escape
#-------------------------------------------------------------------#
sub _escape {
    my $self = shift;
    my $str  = shift;

    $str =~ s/($self->{EscaperRegex})/$self->{Escape}->{$1}/oge;
    return $str;
}
#-------------------------------------------------------------------#





#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The String Consumer `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::StringConsumer;

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $str   = shift;
    $$str = '';
    return bless $str, $class;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# output
#-------------------------------------------------------------------#
sub output {
    my $self = shift;
    my $data = shift;
    $$self .= $data;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize { return $_[0]; }
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The Array Consumer ,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::ArrayConsumer;

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $arr   = shift;
    @$arr = ();
    return bless $arr, $class;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# output
#-------------------------------------------------------------------#
sub output {
    my $self = shift;
    my $data = shift;
    push @$self, $data;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize { return $_[0]; }
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The Handle Consumer `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::HandleConsumer;

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $fh    = shift;
    return bless $fh, $class;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# output
#-------------------------------------------------------------------#
sub output {
    my $self = shift;
    my $data = shift;
    push @$self, $data;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize {
    my $self = shift;
    close $self;
    return 0;
}
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The File Consumer `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::FileConsumer;
use base qw(XML::SAX::Writer::HandleConsumer);

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $file  = shift;

    open XFH, $file or XML::SAX::Writer::Exception->throw({ Message => "Error opening file $file: $!" });
    return SUPER->new(\*XFH);
}
#-------------------------------------------------------------------#



1;
#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, Documentation `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

=pod

=head1 NAME

XML::SAX::Writer - SAX2 XML Writer

=head1 SYNOPSIS

  use XML::SAX::Writer;
  use XML::SAX::SomeDriver;

  my $w = XML::SAX::Writer->new;
  my $d = XML::SAX::SomeDriver->new(Handler => $w);

  $p->parse('some options...');

=head1 DESCRIPTION


=head2 Why yet another XML Writer ?

A new XML Writer was needed to match the SAX2 effort because quite
naturally no existing writer understood SAX2. My first intention had
been to start patching XML::Handler::YAWriter as it had previously
been my favourite writer in the SAX1 world.

However the more I patched it the more I realised that what I thought
was going to be a simple patch (mostly adding a few event handlers and
changing the attribute syntax) was turning out to be a rewrite due to
various ideas I'd been collecting along the way. Besides, I couldn't
find a way to elegantly make it work with SAX2 without breaking the
SAX1 compatibility which people are probably still using. There are of
course ways to do that, but most require user interaction which is
something I wanted to avoid.

So in the end there was a new writer. I think it's in fact better this
way as it helps keep SAX1 and SAX2 separated.

=head1 METHODS

=head1 CREDITS

Michael Koehne (XML::Handler::YAWriter) for much inspiration and
Barrie Slaymaker for the Consumer pattern idea. Of course the usual
suspects (Kip Hampton and Matt Sergeant) helped in the usual ways.

=head1 AUTHOR

Robin Berjon, robin@knowscape.com

=head1 COPYRIGHT

Copyright (c) 2001 Robin Berjon. All rights reserved. This program is
free software; you can redistribute it and/or modify it under the same
terms as Perl itself.

=head1 SEE ALSO

XML::SAX::*

=cut
