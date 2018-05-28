<?xml version="1.1"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" 
	xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:c="http://www.w3.org/ns/xproc-step"  xmlns:nma="tag:conaltuohy.com,2018:nma">
	
	<!-- search result pagination -->
	<xsl:variable name="result-count" select="number(/response/result/@numFound)"/>
	<xsl:variable name="result-count-so-far" select="number(/response/result/@start) + count(/response/result/doc)"/>
	<xsl:variable name="object-type" select="substring-before($relative-uri, '?')"/><!-- e.g. 'object', 'party' etc. -->
	<xsl:variable name="query-parameters" select="tokenize(substring-after($relative-uri, '?'), '&amp;')"/>
	<!-- Generate a link that points to the next page, by constructing a new API query URI with the old 'offset' parameter
	removed, and a new 'offset' parameter which reflects the number of records returned in this response. -->
	<xsl:variable name="next-page-link" select="
		concat(
			$object-type,
			'?',
			string-join(
				(
					$query-parameters
						[not(starts-with(., 'offset='))]
						[substring-after(., '=')],
					concat(
						'offset=', 
						$result-count-so-far
					)
				),
				'&amp;'
			)
		)
	"/>	
	<xsl:variable name="first-page-link" select="
		concat(
			$object-type,
			'?',
			string-join(
				(
					$query-parameters
						[not(starts-with(., 'offset='))]
						[substring-after(., '=')]
				),
				'&amp;'
			)
		)
	"/>
		
	<!-- content negotiation -->
	<!-- if the "format" URL parameter is present, it identifies one of the payload fields; "simple" or "json-ld" -->
	<xsl:param name="format"/>
	<!-- if the format parameter is absent then a format is chosen based on the HTTP "Accept" header -->
	<xsl:param name="accept"/>
	<!-- (or as a last resort the "simple" JSON format is chosen) -->
	
	<!-- the current API query URI, used when generating a "next" link -->
	<xsl:param name="relative-uri"/>
	
	<!-- determine whether the request is a search request, or a retrieval of a single resource -->
	<!-- by attempting to match the request URI to a pattern like "object/12345" --> 
	<xsl:variable name="is-search-request" select="not(matches($relative-uri, '[^/]*/.*'))"/>
	
	<!-- The format to return result data in -->
	<xsl:variable name="response-format">
		<xsl:choose>
			<!-- if the API user has specified a "format" parameter in their request URI, then this is the format chosen -->
			<xsl:when test="$format">
				<xsl:value-of select="$format"/>
			</xsl:when>
			<!-- otherwise, if the API sent an HTTP "Accept" header, and it rates JSON-LD above JSON, then json-ld is the format chosen -->
			<xsl:when test="number(nma:content-type-preference('application/ld+json')) &gt; number(nma:content-type-preference('application/json'))">
				<xsl:text>json-ld</xsl:text>
			</xsl:when>
			<!-- otherwise, the simple JSON output format is chosen -->
			<xsl:otherwise>
				<xsl:text>simple</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:variable>
	
	<!-- a parse tree of the HTTP "Accept" header, e.g.
		<types>
			<type name="application/xml" q="0.1"/>
			<type name="text/html"/>
			<type name="application/json" q="0.5"/>
		</types>
	-->
	<xsl:variable name="accept-header-types">
		<xsl:element name="types">
			<!-- parse the accept header into a list of types, separated by commas -->
			<xsl:analyze-string select="$accept" regex="[^,]+">
				<xsl:matching-substring>
					<xsl:element name="type">
						<!-- parse the type into a MIME content-type, optionally followd by a semi-colon and a bunch of other parameters -->
						<xsl:analyze-string select="normalize-space(.)" regex="([^\s;]+)(.*)">
							<xsl:matching-substring>
								<xsl:attribute name="name" select="regex-group(1)"/>
								<!-- parse the content type parameters (the 'q' content type is a number between 0 and 1 that gives the user's preference rating -->
								<xsl:analyze-string select="regex-group(2)" regex=";\s?([^=]+)=([^;]+)">
									<xsl:matching-substring>
										<xsl:attribute name="{regex-group(1)}" select="regex-group(2)"/>
									</xsl:matching-substring>
								</xsl:analyze-string>
							</xsl:matching-substring>
						</xsl:analyze-string>
					</xsl:element>
				</xsl:matching-substring>
			</xsl:analyze-string>
		</xsl:element>
	</xsl:variable>
	
	<!-- This preference function returns a number from 0 to 1, representing the user's expressed preference for the given content type -->
	<xsl:function name="nma:content-type-preference">
		<xsl:param name="content-type"/>
		<xsl:variable name="specified-type" select="$accept-header-types/types/type[@name=$content-type]"/>
		<xsl:choose>
			<!-- if the content type is not in the Accept header at all, the rating is 0 -->
			<xsl:when test="not($specified-type)">0.0</xsl:when>
			<!-- otherwise the rating is whatever was given in the Accept header -->
			<xsl:otherwise><xsl:value-of select="($specified-type/@q, 1.0)[1]"/></xsl:otherwise>
			<!-- This is not a totally compliant implementation of interpreting an Accept header: -->
			<!-- it doesn't handle high-level content types (e.g. "text/*", or "image/*"), or the "anything" content type "*/*" -->
			<!-- but it's complete enough for our purposes -->
		</xsl:choose>
	</xsl:function>

	<!-- Convert the Solr http response into an API response to the API user -->
	<xsl:template match="/">
		<!-- define the HTTP response; a 404 "Not found" if nothing was found, otherwise a 200 "OK" -->
		<c:response status="{if ($result-count=0) then '404' else '200'}">
			<xsl:call-template name="response-headers"/>
			<!-- specify which format the result is being returned in -->
			<c:body content-type="{if ($response-format='json-ld') then 'application/ld+json' else 'application/json'}">
				<!-- output the actual result data -->
				<xsl:choose>
					<xsl:when test="$is-search-request">
						<!-- URI specified a search request -->
						<xsl:call-template name="return-search-results"/>
					</xsl:when>
					<xsl:otherwise>
						<!-- URI specified a request for a single resource by identifier -->
						<xsl:call-template name="return-single-resource"/>
					</xsl:otherwise>
				</xsl:choose>
			</c:body>
		</c:response>
	</xsl:template>
	
	<xsl:template name="return-single-resource">
		<xsl:apply-templates select="/response/result/doc"/>
	</xsl:template>
	
	<xsl:template name="return-search-results">
		<xsl:choose>
			<xsl:when test="$response-format = 'json-ld'">
				<xsl:text>
				{"context": "/context.json",
				"id": "</xsl:text>
				<xsl:value-of select="$first-page-link"/>
				<xsl:text>",
				"type": "Aggregation",</xsl:text>
				<xsl:if test="$result-count &gt; $result-count-so-far">
					<!-- The current page of records does not exhaust the result set -->
					<xsl:text>"next": "</xsl:text>
					<xsl:value-of select="$next-page-link"/>
					<xsl:text>",</xsl:text>
				</xsl:if>
				<xsl:text>"entities": </xsl:text>
				<xsl:value-of select="$result-count"/>
				<xsl:text>,
				"aggregates": [</xsl:text>
				<xsl:for-each select="/response/result/doc">
					<xsl:if test="position() > 1">
						<xsl:text>,&#xA;</xsl:text>
					</xsl:if>
					<xsl:apply-templates select="."/>
				</xsl:for-each>
				<xsl:text>]
				}</xsl:text>
			</xsl:when>
			<xsl:otherwise><!-- JSON-API -->
				<xsl:text>{"data": [&#xA;</xsl:text>
				<xsl:for-each select="/response/result/doc">
					<xsl:if test="position() > 1">
						<xsl:text>,&#xA;</xsl:text>
					</xsl:if>
					<xsl:apply-templates select="."/>
				</xsl:for-each>
				<xsl:text>], "meta": {"results": </xsl:text>
				<xsl:value-of select="$result-count"/>
				<xsl:text>}</xsl:text>
				<xsl:if test="$result-count &gt; $result-count-so-far">
					<!-- The current page of records does not exhaust the result set -->
					<xsl:text>, "links": {"next": "</xsl:text>
					<xsl:value-of select="$next-page-link"/>
					<xsl:text>"}</xsl:text>
				</xsl:if>
				<xsl:text>}</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>
	
	<xsl:template name="response-headers">
		<xsl:if test="$is-search-request">
			<!-- pagination headers are only useful for search requests because they produce multiple results -->
			<c:header name="Result-Count" value="{$result-count}"/>
			<xsl:if test="$result-count &gt; $result-count-so-far">
				<!-- The current page of records does not exhaust the result set -->
				<c:header name="Link" value="&lt;{$next-page-link}&gt;; rel=next"/>
			</xsl:if>
		</xsl:if>
	</xsl:template>
	
	
	<!-- Represent an individual search result simply by selecting the appropriate format payload field from within it -->
	<xsl:template match="doc">
		<xsl:value-of select="arr[@name=$response-format]"/>
	</xsl:template>
	
	<!-- for errors in JSON-LD, use https://www.w3.org/TR/HTTP-in-RDF10/#example -->
	<!-- http://api.plos.org/search?q=title:assjdfajsdf is a 404 -->
	<!-- http://api.plos.org/search?q=foo:bar is a 400 -->
	<!-- /response/lst[@name='error']/int[@name='code']='400' -->
	<!-- /response/lst[@name='error']/str[@name='msg']='undefined field foo' -->
		
</xsl:stylesheet>
