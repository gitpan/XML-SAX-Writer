
###
# XML::SAX::Writer - SAX2 XML Writer
# Robin Berjon <robin@knowscape.com>
# 26/11/2001 - v0.01
###

package XML::SAX::Writer;
use strict;
use Text::Iconv             qw();
use XML::NamespaceSupport   qw();
use XML::SAX::Exception     qw();
@XML::SAX::Writer::Exception::ISA = qw(XML::SAX::Exception);

use vars qw($VERSION %DEFAULT_ESCAPE);
$VERSION = '0.39';
%DEFAULT_ESCAPE = (
                    '&'     => '&amp;',
                    '<'     => '&lt;',
                    '>'     => '&gt;',
                    '"'     => '&quot;',
                    "'"     => '&apos;',
                    '--'    => '&#45;&#45;',
                  );


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
    $opt->{Output}      ||= *{STDOUT}{IO};

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
    if (lc($self->{EncodeFrom}) ne lc($self->{EncodeTo})) {
        $self->{Encoder} = Text::Iconv->new($self->{EncodeFrom}, $self->{EncodeTo});
    }
    else {
        $self->{Encoder} = XML::SAX::Writer::NullConverter->new;
    }

    $self->{EscaperRegex} = eval 'qr/'                                                .
                            join( '|', map { $_ = "\Q$_\E" } keys %{$self->{Escape}}) .
                            '/;'                                                  ;

    $self->{NSDecl} = [];
    $self->{NSHelper} = XML::NamespaceSupport->new({ xmlns => 1, fatal_errors => 0 });
    $self->{NSHelper}->pushContext;


    # create the Consumer
    my $ref = ref $self->{Output};
    if ($ref eq 'SCALAR') {
        $self->{Consumer} = XML::SAX::Writer::StringConsumer->new($self->{Output});
    }
    elsif ($ref eq 'ARRAY') {
        $self->{Consumer} = XML::SAX::Writer::ArrayConsumer->new($self->{Output});
    }
    elsif (
            $ref eq 'GLOB'                                or
            UNIVERSAL::isa(\$self->{Output}, 'GLOB')      or
            UNIVERSAL::isa($self->{Output}, 'IO::Handle')) {
        $self->{Consumer} = XML::SAX::Writer::HandleConsumer->new($self->{Output});
    }
    elsif (not $ref) {
        $self->{Consumer} = XML::SAX::Writer::FileConsumer->new($self->{Output});
    }
    elsif (UNIVERSAL::can($self->{Output}, 'output')) {
        $self->{Consumer} = $self->{Output};
    }
    else {
        XML::SAX::Writer::Exception->throw( Message => 'Unknown option for Output' );
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

    # create a hash containing the attributes so that we can ensure there is
    # no duplication. Also, we check that ns are properly declared, that the
    # Name is good, etc...
    my %attr_hash;
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
        $attr_hash{$at->{Name}} = $at->{Value};
    }

    for my $nd (@{$self->{NSDecl}}) {
        if ($nd->{Prefix}) {
            $attr_hash{'xmlns:' . $nd->{Prefix}} = $nd->{NamespaceURI};
        }
        else {
            $attr_hash{'xmlns'} = $nd->{NamespaceURI};
        }
    }
    $self->{NSDecl} = [];

    # build a string from what we have, and buffer it
    my $el = '<' . $data->{Name};
    for my $k (keys %attr_hash) {
        $el .= ' ' . $k . '=\'' . $self->_escape($attr_hash{$k}) . '\'';
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
    $self->_output_dtd;

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
    $self->_output_element;
    $self->_output_dtd;

    my $ent;
    if ($data->{Name} =~ m/^%/) {
        $ent = $data->{Name} . ';';
    }
    else {
        $ent = '&' . $data->{Name} . ';';
    }

    $ent = $self->{Encoder}->convert($ent);
    $self->{Consumer}->output($ent);

}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# notation_decl
#-------------------------------------------------------------------#
sub notation_decl {
    my $self = shift;
    my $data = shift;
    $self->_output_dtd;

    # I think that param entities are normalized before this
    my $not = "    <!NOTATION " . $data->{Name};
    if ($data->{PublicId} and $data->{SystemId}) {
        $not .= ' PUBLIC \'' . $self->_escape($data->{PublicId}) . '\' \'' . $self->_escape($data->{SystemId}) . '\'';
    }
    elsif ($data->{PublicId}) {
        $not .= ' PUBLIC \'' . $self->_escape($data->{PublicId}) . '\'';
    }
    else {
        $not .= ' SYSTEM \'' . $self->_escape($data->{SystemId}) . '\'';
    }
    $not .= " >\n";

    $not = $self->{Encoder}->convert($not);
    $self->{Consumer}->output($not);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# unparsed_entity_decl
#-------------------------------------------------------------------#
sub unparsed_entity_decl {
    my $self = shift;
    my $data = shift;
    $self->_output_dtd;

    # I think that param entities are normalized before this
    my $ent = "    <!ENTITY " . $data->{Name};
    if ($data->{PublicId}) {
        $ent .= ' PUBLIC \'' . $self->_escape($data->{PublicId}) . '\' \'' . $self->_escape($data->{SystemId}) . '\'';
    }
    else {
        $ent .= ' SYSTEM \'' . $self->_escape($data->{SystemId}) . '\'';
    }
    $ent .= " NDATA $data->{Notation} >\n";


    $ent = $self->{Encoder}->convert($ent);
    $self->{Consumer}->output($ent);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# element_decl
#-------------------------------------------------------------------#
sub element_decl {
    my $self = shift;
    my $data = shift;
    $self->_output_dtd;

    # I think that param entities are normalized before this
    my $eld = "    <!ELEMENT " . $data->{Name} . ' ' . $data->{Model} . " >\n";
    $eld = $self->{Encoder}->convert($eld);
    $self->{Consumer}->output($eld);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# attribute_decl
#-------------------------------------------------------------------#
sub attribute_decl {
    my $self = shift;
    my $data = shift;
    $self->_output_dtd;

    # I think that param entities are normalized before this
    my $atd = "      <!ATTLIST " . $data->{eName} . ' ' . $data->{aName} . ' ';
    $atd   .= $data->{Type} . ' ' . $data->{ValueDefault} . ' ';
    $atd   .= $data->{Value} . ' ' if $data->{Value};
    $atd   .= " >\n";
    $atd = $self->{Encoder}->convert($atd);
    $self->{Consumer}->output($atd);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# internal_entity_decl
#-------------------------------------------------------------------#
sub internal_entity_decl {
    my $self = shift;
    my $data = shift;
    $self->_output_dtd;

    # I think that param entities are normalized before this
    my $ent = "    <!ENTITY " . $data->{Name} . ' \'' . $self->_escape($data->{Value}) . "' >\n";
    $ent = $self->{Encoder}->convert($ent);
    $self->{Consumer}->output($ent);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# external_entity_decl
#-------------------------------------------------------------------#
sub external_entity_decl {
    my $self = shift;
    my $data = shift;
    $self->_output_dtd;

    # I think that param entities are normalized before this
    my $ent = "    <!ENTITY " . $data->{Name};
    if ($data->{PublicId}) {
        $ent .= ' PUBLIC \'' . $self->_escape($data->{PublicId}) . '\' \'' . $self->_escape($data->{SystemId}) . '\'';
    }
    else {
        $ent .= ' SYSTEM \'' . $self->_escape($data->{SystemId}) . '\'';
    }
    $ent .= " >\n";


    $ent = $self->{Encoder}->convert($ent);
    $self->{Consumer}->output($ent);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# comment
#-------------------------------------------------------------------#
sub comment {
    my $self = shift;
    my $data = shift;
    $self->_output_element;
    $self->_output_dtd;

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

    my $dtd = '<!DOCTYPE ' . $data->{Name};
    if ($data->{PublicId}) {
        $dtd .= ' PUBLIC \'' . $self->_escape($data->{PublicId}) . '\' \'' . $self->_escape($data->{SysmteId}) . '\'';
    }
    elsif ($data->{SystemId}) {
        $dtd .= ' SYSTEM \'' . $self->_escape($data->{SysmteId}) . '\'';
    }

    $self->{BufferDTD} = $dtd;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_dtd
#-------------------------------------------------------------------#
sub end_dtd {
    my $self = shift;
    my $data = shift;

    my $dtd;
    if ($self->{BufferDTD}) {
        $dtd = $self->{BufferDTD} . ' >';
    }
    else {
        $dtd = ' ]>';
    }
    $dtd = $self->{Encoder}->convert($dtd);
    $self->{Consumer}->output($dtd);
    $self->{BufferDTD} = '';
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
    $self->_output_element;
    $self->_output_dtd;

    my $ent;
    if ($data->{Name} eq '[dtd]') {
        # we ignore the fact that we're dealing with an external
        # DTD entity here, and prolly shouldn't write the DTD
        # events unless explicitly told to
        # this will prolly change
    }
    elsif ($data->{Name} =~ m/^%/) {
        $ent = $data->{Name} . ';';
    }
    else {
        $ent = '&' . $data->{Name} . ';';
    }

    $ent = $self->{Encoder}->convert($ent);
    $self->{Consumer}->output($ent);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# end_entity
#-------------------------------------------------------------------#
sub end_entity {
    # depending on what is done above, we might need to do sth here
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
# _output_dtd
#-------------------------------------------------------------------#
sub _output_dtd {
    my $self = shift;

    if ($self->{BufferDTD}) {
        my $dtd = $self->{BufferDTD} . " [\n";
        $dtd = $self->{Encoder}->convert($dtd);
        $self->{Consumer}->output($dtd);
        $self->{BufferDTD} = '';
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
#`,`, The Empty Consumer ,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

# this package is only there to provide a smooth upgrade path in case
# new methods are added to the interface

package XML::SAX::Writer::ConsumerInterface;
sub new {}
sub output {}
sub finalize {}


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The String Consumer `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::StringConsumer;
use base qw(XML::SAX::Writer::ConsumerInterface);

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $str   = shift;
    $$str = '';
    return bless [$str], $class;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# output
#-------------------------------------------------------------------#
sub output {
    my $self = shift;
    my $data = shift;
    ${$self->[0]} .= $data;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize { return $_[0]->[0]; }
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The Array Consumer ,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::ArrayConsumer;
use base qw(XML::SAX::Writer::ConsumerInterface);

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $arr   = shift;
    @$arr = ();
    return bless [$arr], $class;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# output
#-------------------------------------------------------------------#
sub output {
    my $self = shift;
    my $data = shift;
    push @{$self->[0]}, $data;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize { return $_[0]->[0]; }
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The Handle Consumer `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::HandleConsumer;
use base qw(XML::SAX::Writer::ConsumerInterface);

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $fh    = shift;
    return bless [$fh], $class;
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# output
#-------------------------------------------------------------------#
sub output {
    my $self = shift;
    my $data = shift;
    my $fh = $self->[0];
    print $fh $data or XML::SAX::Exception->throw( Message => "Could not write to handle: $fh ($!)" );
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize {
    my $self = shift;
#    close $self;
    return 0;
}
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, The File Consumer `,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::FileConsumer;
use base qw(XML::SAX::Writer::HandleConsumer);
#use Symbol  qw();

#-------------------------------------------------------------------#
# new
#-------------------------------------------------------------------#
sub new {
    my $class = ref($_[0]) ? ref(shift) : shift;
    my $file  = shift or XML::SAX::Writer::Exception->throw(
                            Message => "No filename provided to XML::SAX::Writer::FileConsumer"
                                                            );
#    my $sym = Symbol::gensym;
    local *XFH;
    open XFH, ">$file" or XML::SAX::Writer::Exception->throw(
                                    Message => "Error opening file $file: $!"
                                                            );
    my $self = XML::SAX::Writer::HandleConsumer->new(*{XFH}{IO});
    return bless $self, $class;
#    return SUPER->new(\*$sym);
}
#-------------------------------------------------------------------#

#-------------------------------------------------------------------#
# finalize
#-------------------------------------------------------------------#
sub finalize {
    my $self = shift;
    close $self->[0];
    return 0;
}
#-------------------------------------------------------------------#


#,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,#
#`,`, Noop Converter ,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,`,#
#```````````````````````````````````````````````````````````````````#

package XML::SAX::Writer::NullConverter;
sub new     { return bless [], __PACKAGE__ }
sub convert { $_[1] }


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

  $d->parse('some options...');

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

=over 4

=item * new(%hash)

This is the constructor for this object.  It takes a number of
parameters, all of which are optional.

=item -- Output

This parameter can be one of several things.  If it is a simple
scalar, it is interpreted as a filename which will be opened for
writing.  If it is a scalar reference, output will be appended to this
scalar.  If it is an array reference, output will be pushed onto this
array as it is generated.  If it is a filehandle, then output will be
sent to this filehandle.

Finally, it is possible to pass an object for this parameter, in which
case it is assumed to be an object that implements the consumer
interface L<described later in the documentation|/THE CONSUMER
INTERFACE>.

If this parameter is not provided, then output is sent to STDOUT.

=item -- Escape

This should be a hash reference where the keys are characters
sequences that should be escaped and the values are the escaped form
of the sequence.  By default, this module will escape the ampersand
(&), less than (<), greater than (>), double quote ("), apostrophe
('), and double dash (--) character sequences. Note that the double
dash escape is needed for comments, and that some browsers don't
support the &apos; escape used for apostrophes so that you should
be careful when outputting XHTML.

If you only want to add entries to the Escape hash, you can first
copy the contents of %XML::SAX::Writer::DEFAULT_ESCAPE.

=item -- EncodeFrom

The character set encoding in which incoming data will be provided.
This defaults to UTF-8, which works for US-ASCII as well.

=item -- EncodeTo

The character set encoding in which output should be encoded.  Again,
this defaults to UTF-8.

=back

=head1 GENERATING XML

=head1 THE CONSUMER INTERFACE

XML::SAX::Writer can receive pluggable consumer objects that will be
in charge of writing out the XML formatted by this module. Setting a
Consumer is done by setting the Output option to the object of your
choice instead of to an array, scalar, or file handle as is more
commonly done (internally those in fact map to Consumer classes and
and simply available as options for your convienience).

If you don't understand this, don't worry. You don't need it most of
the time.

That object can be from any class, but must have two methods in its
API. It is also strongly recommended that it inherits from
XML::SAX::Writer::ConsumerInterface so that it will not break if that
interface evolves over time. There are examples at the end of
XML::SAX::Writer's code.

The two methods that it needs to implement are:

=over 4

=item * output(String)

This is called whenever the Writer wants to output a string formatted
in XML. Encoding conversion, character escaping, and formatting have
already taken place. It's up to the consumer to do whatever it wants
with the string.

=item * finalize()

This is called once the document has been output in its entirety,
during the end_document event. end_document will in fact return
whatever finalize() returns, and that in turn should be returned
by parse() for whatever parser was invoked. It might be useful if
you need to provide feedback of some sort.

=back

=head1 TODO

    - make the quote character an option. By default it is here ', but
    I know that a lot of people (for reasons I don't understand but
    won't question :-) prefer to use ". (on most keyboards " is more
    typing, on the rest it's often as much typing).

    - the formatting options need to be developed.

    - test, test, test (and then some tests)

    - doc, doc, doc (actually this part is in better shape)

    - add support for Perl 5.7's Encode module so that we can use it
    instead of Text::Iconv. Encode is more complete and likely to be
    better supported overall. This will be done using a pluggable
    encoder (so that users can provide their own if they want to)
    and detecter both in Makefile.PL requirements and in the module
    at runtime.

=head1 CREDITS

Michael Koehne (XML::Handler::YAWriter) for much inspiration and
Barrie Slaymaker for the Consumer pattern idea. Of course the usual
suspects (Kip Hampton and Matt Sergeant) helped in the usual ways.

=head1 AUTHOR

Robin Berjon, robin@knowscape.com

=head1 COPYRIGHT

Copyright (c) 2001,2002 Robin Berjon. All rights reserved. This program is
free software; you can redistribute it and/or modify it under the same
terms as Perl itself.

=head1 SEE ALSO

XML::SAX::*

=cut

