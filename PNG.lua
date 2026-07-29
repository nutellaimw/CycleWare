local CW = getgenv().__CW_CORE_STATE

local floor   = math.floor
local mmin    = math.min
local mabs    = math.abs
local sbyte   = string.byte
local schar   = string.char
local sformat = string.format
local tconcat = table.concat
local tunpack = table.unpack
local band    = bit32.band
local bxor    = bit32.bxor
local rshift  = bit32.rshift

local function adler32(s)
	local s1, s2 = 1, 0
	for i = 1, #s do
		local b = sbyte(s, i)
		s1 = (s1 + b) % 65521
		s2 = (s2 + s1) % 65521
	end
	return s2 * 65536 + s1
end

local function u32be(n)
	return schar(rshift(n,24), band(rshift(n,16),0xFF),
		band(rshift(n,8),0xFF), band(n,0xFF))
end

local function pngChunk(t, data)
	local p = t..data
	return u32be(#data)..p..u32be(CW.crc32(p))
end

local function literalCode(n)
	if n <= 143 then
		return 0x30 + n, 8
	else
		return 0x190 + (n - 144), 9
	end
end

local function deflateFixedHuffman(raw)
	local outBytes = {}
	local bitbuf, bitcnt = 0, 0

	local function pushBit(bit)
		bitbuf = bitbuf + bit * (2 ^ bitcnt)
		bitcnt = bitcnt + 1
		if bitcnt == 8 then
			outBytes[#outBytes + 1] = schar(bitbuf)
			bitbuf, bitcnt = 0, 0
		end
	end

	local function writeBitsLSB(value, n)
		for i = 0, n - 1 do
			pushBit(band(rshift(value, i), 1))
		end
	end

	local function writeHuffman(code, len)
		for i = len - 1, 0, -1 do
			pushBit(band(rshift(code, i), 1))
		end
	end

	writeBitsLSB(1, 1)
	writeBitsLSB(1, 2)

	for i = 1, #raw do
		local code, len = literalCode(sbyte(raw, i))
		writeHuffman(code, len)
	end

	writeHuffman(0, 7)

	if bitcnt > 0 then
		outBytes[#outBytes + 1] = schar(bitbuf)
	end

	return tconcat(outBytes)
end

function CW.encodePNG(px, w, h)
	local rows = {}
	for y = 0, h-1 do
		local row = {"\0"}
		for x = 0, w-1 do
			local i = (y*w+x)*4+1
			row[#row+1] = schar(px[i], px[i+1], px[i+2], px[i+3])
		end
		rows[y+1] = tconcat(row)
	end
	local raw = tconcat(rows)
	return "\137\80\78\71\13\10\26\10"
		.. pngChunk("IHDR", u32be(w)..u32be(h).."\8\6\0\0\0")
		.. pngChunk("IDAT", "\120\1"..deflateFixedHuffman(raw)..u32be(adler32(raw)))
		.. pngChunk("IEND", "")
end

local COLOR_CHANNELS = {[0]=1, [2]=3, [3]=1, [4]=2, [6]=4}

local function inflate(data)
	local bytes = {}
	for i = 1, #data do bytes[i] = sbyte(data, i) end
	local pos, bitbuf, bitcount = 1, 0, 0
	local out, opos = {}, 1

	local function readbits(n)
		while bitcount < n do
			if pos <= #bytes then bitbuf = bitbuf + bytes[pos] * (2^bitcount); pos = pos+1 end
			bitcount = bitcount + 8
		end
		local v = bitbuf % (2^n)
		bitbuf = floor(bitbuf / (2^n)); bitcount = bitcount - n
		return v
	end

	local function buildTable(lens, nsym)
		local counts, nextcode = {}, {}
		for i = 0, 15 do counts[i] = 0 end
		for i = 0, nsym-1 do local l = lens[i] or 0; counts[l] = counts[l]+1 end
		counts[0] = 0
		local code = 0
		for b = 1, 15 do code = (code + counts[b-1])*2; nextcode[b] = code end
		local tbl = {}
		for sym = 0, nsym-1 do
			local l = lens[sym] or 0
			if l > 0 then
				local c = nextcode[l]; nextcode[l] = c+1
				local rev, tmp = 0, c
				for _ = 1, l do rev = rev*2 + tmp%2; tmp = floor(tmp/2) end
				tbl[rev*16+l] = sym
			end
		end
		return tbl
	end

	local function decode(tbl, maxbits)
		while bitcount < maxbits and pos <= #bytes do
			bitbuf = bitbuf + bytes[pos] * (2^bitcount); pos = pos+1; bitcount = bitcount+8
		end
		for b = 1, maxbits do
			if bitcount >= b then
				local key = (bitbuf % (2^b))*16 + b
				local sym = tbl[key]
				if sym ~= nil then
					bitbuf = floor(bitbuf/(2^b)); bitcount = bitcount-b; return sym
				end
			end
		end
		error("inflate: decode failed at byte "..pos)
	end

	local fixLL, fixD = {}, {}
	for i=0,143 do fixLL[i]=8 end; for i=144,255 do fixLL[i]=9 end
	for i=256,279 do fixLL[i]=7 end; for i=280,287 do fixLL[i]=8 end
	for i=0,31 do fixD[i]=5 end
	local FLL = buildTable(fixLL,288); local FDT = buildTable(fixD,32)

	local LBASE={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local LEXT ={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local DBASE={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local DEXT ={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
	local CLORD={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

	local function decodeBlock(llt, ddt, mLL, mD)
		while true do
			local sym = decode(llt, mLL)
			if sym < 256 then out[opos]=sym; opos=opos+1
			elseif sym == 256 then break
			else
				local len  = LBASE[sym-256] + readbits(LEXT[sym-256])
				local dc   = decode(ddt, mD)
				local dist = DBASE[dc+1] + readbits(DEXT[dc+1])
				local src  = opos - dist
				for _ = 1, len do out[opos]=out[src]; opos=opos+1; src=src+1 end
			end
		end
	end

	repeat
		local bfinal, btype = readbits(1), readbits(2)
		if btype == 0 then
			if bitcount%8 ~= 0 then readbits(bitcount%8) end
			local len = bytes[pos] + bytes[pos+1]*256; pos = pos+4
			for i = 0, len-1 do out[opos]=bytes[pos+i]; opos=opos+1 end
			pos = pos+len
		elseif btype == 1 then decodeBlock(FLL, FDT, 9, 5)
		elseif btype == 2 then
			local hlit  = readbits(5)+257
			local hdist = readbits(5)+1
			local hclen = readbits(4)+4
			local clLens = {}
			for i = 0,18 do clLens[i]=0 end
			for i = 1,hclen do clLens[CLORD[i]]=readbits(3) end
			local CLT = buildTable(clLens, 19)
			local combined, ci = {}, 0
			while ci < hlit+hdist do
				local s = decode(CLT, 7)
				if s <= 15 then combined[ci]=s; ci=ci+1
				elseif s == 16 then local r=readbits(2)+3; for _=1,r do combined[ci]=combined[ci-1]; ci=ci+1 end
				elseif s == 17 then local r=readbits(3)+3; for _=1,r do combined[ci]=0; ci=ci+1 end
				else local r=readbits(7)+11; for _=1,r do combined[ci]=0; ci=ci+1 end end
			end
			local llLens, distLens, mLL, mD = {}, {}, 0, 0
			for i=0,hlit-1  do llLens[i]=combined[i];       if combined[i]>(mLL or 0) then mLL=combined[i] end end
			for i=0,hdist-1 do distLens[i]=combined[hlit+i]; if combined[hlit+i]>(mD or 0) then mD=combined[hlit+i] end end
			decodeBlock(buildTable(llLens,hlit), buildTable(distLens,hdist), mLL, mD)
		else error("inflate: reserved block type") end
	until bfinal == 1

	local parts = {}
	for i = 1, opos-1, 4096 do
		parts[#parts+1] = schar(tunpack(out, i, mmin(i+4095, opos-1)))
	end
	return tconcat(parts)
end

function CW.parsePNG(data)
	assert(data:sub(1,8) == "\137\80\78\71\13\10\26\10", "not a PNG")
	local pos, w, h, bitDepth, colorType = 9
	local idatParts, palette, transAlpha = {}, {}, {}

	while pos <= #data do
		local len   = sbyte(data,pos)*16777216 + sbyte(data,pos+1)*65536
					+ sbyte(data,pos+2)*256    + sbyte(data,pos+3)
		local typ   = data:sub(pos+4, pos+7)
		local chunk = data:sub(pos+8, pos+8+len-1)
		pos = pos + 12 + len

		if typ == "IHDR" then
			w         = sbyte(chunk,1)*16777216+sbyte(chunk,2)*65536+sbyte(chunk,3)*256+sbyte(chunk,4)
			h         = sbyte(chunk,5)*16777216+sbyte(chunk,6)*65536+sbyte(chunk,7)*256+sbyte(chunk,8)
			bitDepth  = sbyte(chunk,9)
			colorType = sbyte(chunk,10)
			assert(bitDepth==8 or (colorType==3 and bitDepth<=8), "parsePNG: unsupported bit depth "..bitDepth)
		elseif typ == "PLTE" then
			for i = 0, floor(#chunk/3)-1 do
				palette[i] = {sbyte(chunk,i*3+1), sbyte(chunk,i*3+2), sbyte(chunk,i*3+3)}
			end
		elseif typ == "tRNS" then
			if colorType == 3 then for i=1,#chunk do transAlpha[i-1]=sbyte(chunk,i) end end
		elseif typ == "IDAT" then idatParts[#idatParts+1] = chunk
		elseif typ == "IEND" then break end
	end

	local ch = COLOR_CHANNELS[colorType]
	assert(ch, "parsePNG: unsupported colorType "..tostring(colorType))

	local rawData = inflate(tconcat(idatParts):sub(3, -5))
	local stride, px, rpos, prev = w*ch, {}, 1, {}
	for i = 1, stride do prev[i] = 0 end

	for y = 0, h-1 do
		local ftype = sbyte(rawData, rpos); rpos = rpos+1
		local row = {}
		for x = 1, stride do
			local b  = sbyte(rawData, rpos); rpos = rpos+1
			local a  = row[x-ch] or 0
			local up = prev[x]   or 0
			local ul = prev[x-ch] or 0
			if     ftype==0 then row[x]=b
			elseif ftype==1 then row[x]=(b+a)%256
			elseif ftype==2 then row[x]=(b+up)%256
			elseif ftype==3 then row[x]=(b+floor((a+up)/2))%256
			elseif ftype==4 then
				local p=a+up-ul
				local pa,pb,pc=mabs(p-a),mabs(p-up),mabs(p-ul)
				row[x]=(b+(pa<=pb and pa<=pc and a or pb<=pc and up or ul))%256
			end
		end
		prev = row
		for x = 0, w-1 do
			local dst, s = (y*w+x)*4+1, x*ch+1
			if     colorType==6 then px[dst]=row[s];px[dst+1]=row[s+1];px[dst+2]=row[s+2];px[dst+3]=row[s+3]
			elseif colorType==2 then px[dst]=row[s];px[dst+1]=row[s+1];px[dst+2]=row[s+2];px[dst+3]=255
			elseif colorType==0 then px[dst]=row[s];px[dst+1]=row[s];  px[dst+2]=row[s];  px[dst+3]=255
			elseif colorType==4 then px[dst]=row[s];px[dst+1]=row[s];  px[dst+2]=row[s];  px[dst+3]=row[s+1]
			elseif colorType==3 then
				local pal=palette[row[s]] or {255,255,255}
				px[dst]=pal[1];px[dst+1]=pal[2];px[dst+2]=pal[3]
				px[dst+3]=transAlpha[row[s]] ~= nil and transAlpha[row[s]] or 255
			end
		end
	end
	return px, w, h
end

function CW.resizePixels(px, w, h, tw, th)
	if tw==w and th==h then return px,w,h end
	local out, scaleX, scaleY = {}, w/tw, h/th
	for y=0,th-1 do
		local srcY = mmin(floor(y*scaleY), h-1)
		for x=0,tw-1 do
			local srcX = mmin(floor(x*scaleX), w-1)
			local src=(srcY*w+srcX)*4+1; local dst=(y*tw+x)*4+1
			out[dst]=px[src] or 0; out[dst+1]=px[src+1] or 0
			out[dst+2]=px[src+2] or 0; out[dst+3]=px[src+3] or 0
		end
	end
	CW.Log(sformat("Resized to %d×%d", tw, th))
	return out, tw, th
end

function CW.applyTint(px, w, h, tR, tG, tB)
	local out = {}
	for i=1, w*h*4, 4 do
		local r,g,b,a = px[i] or 0, px[i+1] or 0, px[i+2] or 0, px[i+3] or 0
		if a > 10 then
			local lum = (0.299*r + 0.587*g + 0.114*b) / 255
			out[i]  =mmin(255,floor(lum*tR+0.5))
			out[i+1]=mmin(255,floor(lum*tG+0.5))
			out[i+2]=mmin(255,floor(lum*tB+0.5))
			out[i+3]=a
		else out[i]=0; out[i+1]=0; out[i+2]=0; out[i+3]=0 end
	end
	return out
end
